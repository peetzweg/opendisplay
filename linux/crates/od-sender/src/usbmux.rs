//! USB transport via usbmuxd (Apple devices) (§2.2).
//!
//! Connects to `/var/run/usbmuxd` and tunnels TCP port 9000 on the chosen
//! iOS/iPadOS device into a transparent byte pipe.

use std::path::Path;
use anyhow::{Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tracing::info;

pub const USBMUXD_SOCKET: &str = "/var/run/usbmuxd";

#[derive(Debug, Clone)]
pub struct UsbDevice {
    pub device_id: u32,
    pub serial: Option<String>,
    pub connection_type: Option<String>,
}

fn encode_packet(payload: &str, tag: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(16 + payload.len());
    let len = (16 + payload.len()) as u32;
    buf.extend_from_slice(&len.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes()); // version = 1
    buf.extend_from_slice(&8u32.to_le_bytes()); // request = 8 (plist)
    buf.extend_from_slice(&tag.to_le_bytes());
    buf.extend_from_slice(payload.as_bytes());
    buf
}

async fn read_packet(stream: &mut UnixStream) -> Result<(u32, String)> {
    let mut hdr = [0u8; 16];
    stream.read_exact(&mut hdr).await.context("reading usbmuxd header")?;
    let len = u32::from_le_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as usize;
    let tag = u32::from_le_bytes([hdr[12], hdr[13], hdr[14], hdr[15]]);
    if len < 16 {
        anyhow::bail!("invalid usbmuxd packet length: {len}");
    }
    let payload_len = len - 16;
    let mut payload = vec![0u8; payload_len];
    stream.read_exact(&mut payload).await.context("reading usbmuxd payload")?;
    let text = String::from_utf8(payload).context("invalid utf-8 in usbmuxd payload")?;
    Ok((tag, text))
}

pub fn parse_devices(xml: &str) -> Vec<UsbDevice> {
    let mut devices = Vec::new();
    for part in xml.split("<dict>").skip(1) {
        if let Some(dict_content) = part.split("</dict>").next() {
            if let Some(id) = extract_integer(dict_content, "DeviceID") {
                let serial = extract_string(dict_content, "SerialNumber");
                let conn_type = extract_string(dict_content, "ConnectionType");
                if !devices.iter().any(|d: &UsbDevice| d.device_id == id) {
                    devices.push(UsbDevice {
                        device_id: id,
                        serial,
                        connection_type: conn_type,
                    });
                }
            }
        }
    }
    devices
}

fn extract_integer(haystack: &str, key: &str) -> Option<u32> {
    let pattern = format!("<key>{key}</key>");
    let pos = haystack.find(&pattern)?;
    let rem = &haystack[pos + pattern.len()..];
    let int_start = rem.find("<integer>")? + "<integer>".len();
    let int_end = rem[int_start..].find("</integer>")?;
    rem[int_start..int_start + int_end].trim().parse::<u32>().ok()
}

fn extract_string(haystack: &str, key: &str) -> Option<String> {
    let pattern = format!("<key>{key}</key>");
    let pos = haystack.find(&pattern)?;
    let rem = &haystack[pos + pattern.len()..];
    let str_start = rem.find("<string>")? + "<string>".len();
    let str_end = rem[str_start..].find("</string>")?;
    Some(rem[str_start..str_start + str_end].trim().to_string())
}

/// Query connected Apple devices via usbmuxd.
pub async fn list_devices() -> Result<Vec<UsbDevice>> {
    if !Path::new(USBMUXD_SOCKET).exists() {
        return Ok(Vec::new());
    }
    let mut stream = UnixStream::connect(USBMUXD_SOCKET)
        .await
        .with_context(|| format!("connecting to usbmuxd at {USBMUXD_SOCKET}"))?;
    let req = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MessageType</key><string>ListDevices</string>
    <key>ProgName</key><string>od-sender</string>
    <key>ClientVersionString</key><string>1.0</string>
</dict>
</plist>"#;
    stream.write_all(&encode_packet(req, 1)).await?;
    let (_, resp) = read_packet(&mut stream).await?;
    Ok(parse_devices(&resp))
}

/// Connect to TCP port 9000 on an iOS/iPadOS device over usbmuxd (§2.2).
pub async fn connect(device_id: Option<u32>) -> Result<UnixStream> {
    let target_id = match device_id {
        Some(id) => id,
        None => {
            let devices = list_devices().await?;
            if devices.is_empty() {
                anyhow::bail!(
                    "no USB devices found via usbmuxd at {USBMUXD_SOCKET}; \
                     plug in iPhone/iPad with a data cable and check that usbmuxd is running"
                );
            }
            let chosen = devices
                .iter()
                .find(|d| d.connection_type.as_deref() == Some("USB"))
                .unwrap_or(&devices[0]);
            info!(
                "selected USB device {} (serial: {:?})",
                chosen.device_id, chosen.serial
            );
            chosen.device_id
        }
    };

    let mut stream = UnixStream::connect(USBMUXD_SOCKET)
        .await
        .with_context(|| format!("connecting to usbmuxd at {USBMUXD_SOCKET}"))?;

    // OpenDisplay listens on port 9000 (§1).
    // usbmuxd expects PortNumber in network byte order (big-endian).
    let port_be = opendisplay_proto::DEFAULT_PORT.to_be();
    let connect_req = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MessageType</key><string>Connect</string>
    <key>ClientVersionString</key><string>od-sender</string>
    <key>ProgName</key><string>od-sender</string>
    <key>DeviceID</key><integer>{target_id}</integer>
    <key>PortNumber</key><integer>{port_be}</integer>
</dict>
</plist>"#
    );

    stream.write_all(&encode_packet(&connect_req, 2)).await?;
    let (_, resp) = read_packet(&mut stream).await?;
    let res_num = extract_integer(&resp, "Number").unwrap_or(1);
    if res_num != 0 {
        anyhow::bail!(
            "usbmuxd connect to device {target_id} port {} failed (code {res_num}). \
             Is OpenDisplay open on the device?",
            opendisplay_proto::DEFAULT_PORT
        );
    }

    info!("connected to device {target_id} over USB (usbmuxd)");
    Ok(stream)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_and_parse() {
        let packet = encode_packet("<test/>", 42);
        assert_eq!(packet.len(), 16 + 7);
        assert_eq!(&packet[0..4], &(23u32).to_le_bytes());
        assert_eq!(&packet[4..8], &1u32.to_le_bytes());
        assert_eq!(&packet[8..12], &8u32.to_le_bytes());
        assert_eq!(&packet[12..16], &42u32.to_le_bytes());
        assert_eq!(&packet[16..], b"<test/>");

        let xml = r#"
        <dict>
            <key>DeviceList</key>
            <array>
                <dict>
                    <key>DeviceID</key><integer>7</integer>
                    <key>Properties</key>
                    <dict>
                        <key>SerialNumber</key><string>abc123xyz</string>
                        <key>ConnectionType</key><string>USB</string>
                    </dict>
                </dict>
            </array>
        </dict>
        "#;
        let devices = parse_devices(xml);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].device_id, 7);
        assert_eq!(devices[0].serial.as_deref(), Some("abc123xyz"));
        assert_eq!(devices[0].connection_type.as_deref(), Some("USB"));

        assert_eq!(extract_integer("<key>Number</key><integer>0</integer>", "Number"), Some(0));
        assert_eq!(extract_integer("<key>Number</key><integer>3</integer>", "Number"), Some(3));
        assert_eq!(opendisplay_proto::DEFAULT_PORT.to_be(), 10275);
    }
}
