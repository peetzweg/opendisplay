// Curated from GitHub issue #220. Keep this as link metadata, not a hand-made
// imitation of the source site: titles can be long, multilingual, or change
// without breaking the layout. `tools/collect-coverage.mjs` refreshes fields
// from Open Graph metadata when a publication supplies it.
export type Coverage = {
  kind: "coverage"
  url: string
  site: string
  title: string
  description: string
  image?: string
  post?: {
    author: string
    handle: string
    date: string
    text: string
  }
}

export const COVERAGE: Coverage[] = [
  {
    kind: "coverage",
    url: "https://www.macgadget.de/index.php/News/2026/08/12/OpenDisplay-iPhone-oder-iPad-als-Zusatzmonitor-fuer-den-Mac-nutzen",
    site: "MacGadget",
    title: "OpenDisplay: iPhone oder iPad als Zusatzmonitor für den Mac nutzen",
    description: "News and background on Apple, Mac, iPhone and iPad.",
  },
  {
    kind: "coverage",
    url: "https://applech2.com/archives/20260809-opendisplay-support-apple-pencil-pressure.html",
    site: "Applech2",
    title: "iPadにMacの画面を映しセカンドモニターとして利用できるようにするアプリ「OpenDisplay」がApple Pencilの筆圧とチルト、ホバーに対応。",
    description: "OpenDisplayはドイツのPhilip Poloczekさんがオープンソースで開発しているAppleデバイス用モニターアプリで、iPadにMacの画面を映し出しMacのセカンドモニターとして使用できるようにしてくれますが、このOpenDisplayがバージョン1.15.0でApple Pencilの機能に対応しています。",
    image: "https://applech2.com/wp-content/uploads/2026/08/Opendisplay-support-Apple-Pencil-pressure-and-tilt-Hero-v2.webp",
  },
  {
    kind: "coverage",
    url: "https://www.ifun.de/opendisplay-kostenlose-sidecar-alternative-aus-deutschland-283401",
    site: "ifun.de",
    title: "OpenDisplay: kostenlose Sidecar-Alternative aus Deutschland",
    description: "Wer ein iPhone oder iPad als zusätzlichen Bildschirm für den Mac verwenden möchte, ist bislang meist auf Apples Sidecar angewiesen. Mit OpenDisplay steht nun eine Alternative bereit, die einen anderen Ansatz verfolgt und dabei auf eine Reihe von Einschränkungen verzichtet, die Apples Lösung mit sich bringt.",
    image: "https://images.ifun.de/wp-content/uploads/2026/07/opensidecar-feature.jpg",
  },
  {
    kind: "coverage",
    url: "https://www.sir-apfelot.de/opendisplay-70912/",
    site: "Sir Apfelot",
    title: "Statt Sidecar: OpenDisplay erweitert Mac-Display auf iPhone und iPad",
    description: "Mit OpenDisplay lässt sich das iPhone oder iPad als zusätzliches Mac-Display nutzen. Dafür müssen die Geräte noch nichtmal den gleichen Apple Account nutzen.",
    image: "https://www.sir-apfelot.de/wp-content/uploads/2026/07/opendisplay-sidecar-alternative.jpg",
  },
  {
    kind: "coverage",
    url: "https://www.appgefahren.de/opendisplay-kostenlose-open-source-app-nutzt-ipad-als-zweites-mac-display-403961.html",
    site: "appgefahren.de",
    title: "OpenDisplay: Kostenlose Open-Source-App nutzt iPad als zweites Mac-Display",
    description: "Mit der OpenDisplay-App des unabhängigen Entwicklers Philip Polosczek lassen sich kostenlos iPads und iPhones als zweiter Bildschirm nutzen.",
    image: "https://www.appgefahren.de/wp-content/uploads/2026/08/OpenDisplay-Mac-iPad.jpg",
  },
  ...[
    ["https://x.com/z12789/status/2087988422824837490", "damo", "z12789", "August 13, 2026", "之前通过Mac OS sidecar 把iPad 作为副屏使用，但是只能横屏不能竖屏。最后发现免费方案 OpenDisplay 很好的解决了这个问题。"],
    ["https://x.com/CamilleRoux/status/2080291868101812582", "Camille Roux", "CamilleRoux", "July 23, 2026", "OpenDisplay : utilisez votre iPhone ou iPad comme second écran pour votre Mac, en USB ou WiFi. Open source, gratuit, sans compte, sans dongle."],
    ["https://x.com/aladagberk/status/2083230517537718553", "Berk Aladag", "aladagberk", "July 31, 2026", "Eski iPhone veya iPad'in çekmecede duruyorsa, onu Mac'in için gerçek bir ikinci monitöre dönüştürebilirsin. OpenDisplay; Apple Sidecar ve Duet Display'e ücretsiz, açık kaynaklı bir alternatif."],
    ["https://x.com/oliviscusAI/status/2082506100021305653", "Oliver Prompts", "oliviscusAI", "July 29, 2026", "Apple's Sidecar only works if your iPad and Mac share the same Apple ID. Duet charges a subscription. OpenDisplay does it free, no account, no dongle."],
    ["https://x.com/RocM301/status/2077288370334740496", "小鹏Digital", "RocM301", "July 15, 2026", "OpenDisplay还是蛮好玩的，使用的usb-c连接。iPad mini作为副屏延迟很好，保留了触摸体验。它不需要像系统内置的Sidecar那样要求同一个Apple ID。"],
    ["https://x.com/RocM301/status/2076896134455566495", "小鹏Digital", "RocM301", "July 14, 2026", "闲置iPhone/iPad变Mac第二屏？OpenDisplay免费开源版来了！不用Sidecar限制、不用Duet订阅，直接USB或WiFi连，低延迟Retina画质还能触屏操作！"],
    ["https://x.com/okdt/status/2086467678991180198", "オカダリョウタロウ", "okdt", "August 9, 2026", "OpenDisplay 使ってみてる。iPhone/iPadがMacの拡張ディスプレイになる。無料・アカウント不要、外部サーバー・テレメトリはないGPL-3.0のOSS。"],
    ["https://x.com/MacGeneration/status/2079841743303057559", "MacGeneration", "MacGeneration", "July 22, 2026", "OpenDisplay : l’alternative gratuite à Sidecar qui supprime plusieurs limites d’Apple."],
    ["https://x.com/GcZsmkv/status/2073793241083003241", "阿尼欧Tiffany", "GcZsmkv", "July 5, 2026", "🪄平替工具：免费且开源的将你的 iPhone 或 iPad 变成 Mac 的扩展显示器工具“OpenDisplay”，就像是Apple Sidecar（随航）功能的一个开源替代品。"],
  ].map(([url, author, handle, date, text]) => ({
    kind: "coverage" as const,
    url,
    site: "X",
    title: `${author} on X`,
    description: text,
    post: { author, handle, date, text },
  })),
]
