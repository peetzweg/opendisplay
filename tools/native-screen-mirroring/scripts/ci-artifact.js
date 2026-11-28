import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkRelease } from './check-release.js';

const hash = value => createHash('sha256').update(value).digest('hex');
export function validateRun(run, repository, sourceCommit) {
  if (run.repository?.full_name !== repository || run.head_repository?.full_name !== repository ||
      run.path !== '.github/workflows/native-screen-mirroring.yml' || run.head_branch !== 'main' ||
      !['push', 'workflow_dispatch'].includes(run.event) || run.conclusion !== 'success' ||
      run.head_sha !== sourceCommit) throw new Error('Untrusted, unsuccessful or mismatched candidate run');
}
export function candidateName(candidate) {
  if (!/^\d+\.\d+\.\d+$/.test(candidate.version) || !['arm64', 'x86_64'].includes(candidate.architecture) ||
      candidate.artifact !== `iPhone-Native-Mirror-${candidate.version}-${candidate.architecture}.zip` ||
      !/^[a-f0-9]{40}$/.test(candidate.sourceCommit) || candidate.sourceClean !== true)
    throw new Error('Invalid candidate metadata');
  return `native-mirror-v${candidate.version}-${candidate.architecture}-${candidate.sourceCommit.slice(0, 12)}`;
}
export function verifyArtifact(directory, { spawn = spawnSync } = {}) {
  directory = path.resolve(directory);
  const candidate = JSON.parse(readFileSync(path.join(directory, 'candidate.json')));
  candidateName(candidate);
  const zip = path.join(directory, candidate.artifact);
  if (hash(readFileSync(zip)) !== candidate.artifactSHA256) throw new Error('Installer checksum mismatch');
  const unpacked = path.join(directory, 'extracted');
  mkdirSync(unpacked); // A fresh extraction is mandatory.
  const run = (binary, args, options = {}) => {
    const result = spawn(binary, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options });
    if (result.error || result.status !== 0) throw new Error(`${binary} failed: ${result.stderr || result.error || result.status}`);
    return result.stdout;
  };
  run('/usr/bin/ditto', ['-x', '-k', zip, unpacked]);
  const app = path.join(unpacked, 'Install iPhone Native Mirror.app');
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const runtime = path.join(app, 'Contents/Resources/runtime');
  const tests = readdirSync(path.join(runtime, 'test')).filter(name => name.endsWith('.test.js')).sort();
  const result = spawn(path.join(runtime, 'node'), ['--test', '--test-reporter=tap', ...tests.map(name => `test/${name}`)],
    { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, cwd: runtime,
      env: { ...process.env, RUN_NATIVE_TESTS: '1', RUN_VIRTUAL_TESTS: '1', RUN_VIDEO_TESTS: '1', RUN_SOAK_TESTS: '1' } });
  // Node's test reporter writes failures to stdout. Retain it before checking
  // status so a failed packaged test is diagnosable instead of just "exit 1".
  writeFileSync(path.join(directory, 'tests.tap'), result.stdout || '');
  writeFileSync(path.join(directory, 'tests.stderr.log'), result.stderr || '');
  if (result.error || result.status !== 0)
    throw new Error(`Extracted installer tests failed: ${result.error?.message || result.status}\n${result.stdout || ''}\n${result.stderr || ''}`);
  return candidate;
}
export function approve(directory, evidenceFile, runFile, repository) {
  const candidate = JSON.parse(readFileSync(path.join(directory, 'candidate.json')));
  validateRun(JSON.parse(readFileSync(runFile)), repository, candidate.sourceCommit);
  const tag = candidateName(candidate);
  const nativeLog = readFileSync(path.join(directory, 'native-tests.log'), 'utf8');
  if (!/100% tests passed[^\n]*\b2\b/.test(nativeLog) || /[1-9]\d* tests failed/.test(nativeLog))
    throw new Error('Missing successful native CTest results');
  const evidence = JSON.parse(readFileSync(evidenceFile));
  // Automated evidence is generated here, never accepted from the human record.
  evidence.automated = { status: 'passed', runtime: 'extracted-installer', log: 'tests.tap',
    logSHA256: hash(readFileSync(path.join(directory, 'tests.tap'))) };
  evidence.native = { status: 'passed', evidence: nativeLog };
  writeFileSync(path.join(directory, 'evidence.json'), JSON.stringify(evidence, null, 2));
  checkRelease(path.join(directory, 'candidate.json'), path.join(directory, 'evidence.json'));
  writeFileSync(path.join(directory, 'SHA256SUMS.txt'), `${candidate.artifactSHA256}  ${candidate.artifact}\n`);
  writeFileSync(path.join(directory, 'release.json'), JSON.stringify({ tag, sourceCommit: candidate.sourceCommit, artifact: candidate.artifact }));
  const notes = `Self-contained review installer. Not notarized.\n\nDownload and unzip **${candidate.artifact}**, then open the installer. If macOS blocks it, click **Done**, keep the extracted app, then open **System Settings → Privacy & Security → Open Anyway**. Click **Install**, then **Done**. Open OpenDisplay on your iPhone, then select **Control Center → Screen Mirroring → iPhone** on your Mac.\n\nUsing Sidecar too? Connect the iPad first. Connecting it after iPhone is blocked by macOS.\n\nUninstall:\n\n\`\`\`sh\nif [ -x "$HOME/Library/Application Support/iphone-native-mirror/runtime/node" ]; then "$HOME/Library/Application Support/iphone-native-mirror/runtime/node" "$HOME/Library/Application Support/iphone-native-mirror/runtime/scripts/bundle-setup.js" --remove; else printf 'Already uninstalled\\n'; fi\n\`\`\`\n\nValidation is attached in evidence.json and tests.tap. Physical results are human attestations for this exact ZIP.\n\n${evidence.limitations.map(item => `- ${item}`).join('\n')}\n`;
  writeFileSync(path.join(directory, 'RELEASE.md'), notes);
  return { tag };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const [mode, directory, evidence, runFile, repository] = process.argv.slice(2);
    if (mode === 'verify') verifyArtifact(directory);
    else if (mode === 'approve') console.log(JSON.stringify(approve(directory, evidence, runFile, repository)));
    else throw new Error('Expected verify or approve');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
