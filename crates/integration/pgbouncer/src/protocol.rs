use std::{collections::BTreeMap, io};

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

const MAX_PACKET_LENGTH: usize = 64 * 1024 * 1024;
const MAX_ENCRYPTION_NEGOTIATIONS: usize = 5;
const SSL_REQUEST: u32 = 80_877_103;
const GSSENC_REQUEST: u32 = 80_877_104;

#[derive(Debug)]
pub struct Startup {
    pub raw: Vec<u8>,
    pub parameters: BTreeMap<String, String>,
}

#[derive(Debug)]
pub struct Frame {
    pub tag: u8,
    pub raw: Vec<u8>,
}

#[derive(Clone, Debug, Default)]
pub struct BackendParameters {
    statuses: Vec<(String, String)>,
}

impl BackendParameters {
    pub fn admin() -> Self {
        Self {
            statuses: vec![
                ("client_encoding".to_string(), "UTF8".to_string()),
                ("server_encoding".to_string(), "UTF8".to_string()),
                ("server_version".to_string(), "18.3".to_string()),
                ("server_version_num".to_string(), "180003".to_string()),
                ("standard_conforming_strings".to_string(), "on".to_string()),
                ("integer_datetimes".to_string(), "on".to_string()),
                ("DateStyle".to_string(), "ISO, MDY".to_string()),
            ],
        }
    }
}

pub async fn read_startup(client: &mut TcpStream) -> io::Result<Startup> {
    let mut negotiation_rounds = 0;
    loop {
        let raw = read_untyped_packet(client).await?;
        let code = u32::from_be_bytes(raw[4..8].try_into().expect("startup code length"));
        if matches!(code, SSL_REQUEST | GSSENC_REQUEST) {
            negotiation_rounds += 1;
            if negotiation_rounds > MAX_ENCRYPTION_NEGOTIATIONS {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "too many encryption negotiation attempts",
                ));
            }
            client.write_all(b"N").await?;
            continue;
        }
        if code != 196_608 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported PostgreSQL startup protocol {code}"),
            ));
        }
        return Ok(Startup {
            parameters: parse_startup_parameters(&raw)?,
            raw,
        });
    }
}

pub async fn read_frame(stream: &mut TcpStream) -> io::Result<Frame> {
    let mut tag = [0; 1];
    stream.read_exact(&mut tag).await?;
    let mut length = [0; 4];
    stream.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    validate_packet_length(length)?;
    let mut raw = Vec::with_capacity(length + 1);
    raw.push(tag[0]);
    raw.extend_from_slice(&(length as u32).to_be_bytes());
    raw.resize(length + 1, 0);
    stream.read_exact(&mut raw[5..]).await?;
    Ok(Frame { tag: tag[0], raw })
}

pub async fn begin_backend_session(
    client: &mut TcpStream,
    backend: &mut TcpStream,
    startup: &Startup,
) -> io::Result<BackendParameters> {
    backend.write_all(&startup.raw).await?;
    backend.flush().await?;
    let mut parameters = BackendParameters::default();
    loop {
        let frame = read_frame(backend).await?;
        client.write_all(&frame.raw).await?;
        if frame.tag == b'S' {
            parameters.record(&frame.raw)?;
        }
        if frame.tag == b'R' && authentication_needs_response(&frame.raw) {
            client.flush().await?;
            let response = read_frame(client).await?;
            backend.write_all(&response.raw).await?;
            backend.flush().await?;
        }
        if frame.tag == b'Z' {
            client.flush().await?;
            return Ok(parameters);
        }
    }
}

pub async fn send_pooled_startup(
    client: &mut TcpStream,
    parameters: &BackendParameters,
) -> io::Result<()> {
    write_frame(client, b'R', &0_u32.to_be_bytes()).await?;
    for (key, value) in &parameters.statuses {
        write_parameter_status(client, key, value).await?;
    }
    write_frame(client, b'Z', b"I").await?;
    client.flush().await
}

pub async fn relay_until_ready(
    backend: &mut TcpStream,
    client: &mut TcpStream,
) -> io::Result<()> {
    loop {
        let frame = read_frame(backend).await?;
        client.write_all(&frame.raw).await?;
        if frame.tag == b'Z' {
            client.flush().await?;
            return Ok(());
        }
    }
}

pub async fn relay_flush_responses(
    backend: &mut TcpStream,
    client: &mut TcpStream,
) -> io::Result<()> {
    // Wait for the backend to produce at least one response after Flush.
    backend.readable().await?;
    loop {
        let mut peek_buf = [0; 1];
        match backend.try_read(&mut peek_buf) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "backend closed while relaying Flush responses",
                ));
            }
            Ok(_) => {
                let frame = read_frame_with_first_byte(backend, peek_buf[0]).await?;
                client.write_all(&frame.raw).await?;
                if frame.tag == b'Z' {
                    client.flush().await?;
                }
            }
            Err(ref error) if error.kind() == io::ErrorKind::WouldBlock => {
                client.flush().await?;
                return Ok(());
            }
            Err(error) => return Err(error),
        }
    }
}

async fn read_frame_with_first_byte(stream: &mut TcpStream, tag: u8) -> io::Result<Frame> {
    let mut length = [0; 4];
    stream.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    validate_packet_length(length)?;
    let mut raw = Vec::with_capacity(length + 1);
    raw.push(tag);
    raw.extend_from_slice(&(length as u32).to_be_bytes());
    raw.resize(length + 1, 0);
    stream.read_exact(&mut raw[5..]).await?;
    Ok(Frame { tag, raw })
}

pub async fn discard_until_ready(backend: &mut TcpStream, query: &str) -> io::Result<()> {
    let mut payload = query.as_bytes().to_vec();
    payload.push(0);
    write_frame(backend, b'Q', &payload).await?;
    backend.flush().await?;
    loop {
        if read_frame(backend).await?.tag == b'Z' {
            return Ok(());
        }
    }
}

pub async fn write_frame(stream: &mut TcpStream, tag: u8, payload: &[u8]) -> io::Result<()> {
    let length = u32::try_from(payload.len() + 4).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "PostgreSQL packet is too large",
        )
    })?;
    let mut frame = Vec::with_capacity(payload.len() + 5);
    frame.push(tag);
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(payload);
    stream.write_all(&frame).await
}

async fn read_untyped_packet(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut length = [0; 4];
    stream.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    if length < 8 || length > MAX_PACKET_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid startup packet length {length}"),
        ));
    }
    let mut raw = Vec::with_capacity(length);
    raw.extend_from_slice(&(length as u32).to_be_bytes());
    raw.resize(length, 0);
    stream.read_exact(&mut raw[4..]).await?;
    Ok(raw)
}

fn parse_startup_parameters(raw: &[u8]) -> io::Result<BTreeMap<String, String>> {
    let mut parameters = BTreeMap::new();
    let mut fields = raw[8..].split(|byte| *byte == 0);
    loop {
        let Some(key) = fields.next() else {
            break;
        };
        if key.is_empty() {
            break;
        }
        let Some(value) = fields.next() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "startup packet ends before parameter value",
            ));
        };
        let key = std::str::from_utf8(key).map_err(invalid_utf8)?;
        let value = std::str::from_utf8(value).map_err(invalid_utf8)?;
        parameters.insert(key.to_string(), value.to_string());
    }
    Ok(parameters)
}

fn authentication_needs_response(raw: &[u8]) -> bool {
    if raw.len() < 9 {
        return false;
    }
    matches!(
        u32::from_be_bytes(raw[5..9].try_into().expect("authentication code length")),
        3 | 5 | 7 | 8 | 10 | 11
    )
}

async fn write_parameter_status(
    stream: &mut TcpStream,
    key: &str,
    value: &str,
) -> io::Result<()> {
    let mut payload = Vec::with_capacity(key.len() + value.len() + 2);
    payload.extend_from_slice(key.as_bytes());
    payload.push(0);
    payload.extend_from_slice(value.as_bytes());
    payload.push(0);
    write_frame(stream, b'S', &payload).await
}

impl BackendParameters {
    fn record(&mut self, raw: &[u8]) -> io::Result<()> {
        let payload = raw.get(5..).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "ParameterStatus has no payload")
        })?;
        let mut fields = payload.split(|byte| *byte == 0);
        let key = fields.next().filter(|key| !key.is_empty()).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "ParameterStatus is missing a name",
            )
        })?;
        let value = fields.next().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "ParameterStatus is missing a value",
            )
        })?;
        let key = std::str::from_utf8(key).map_err(invalid_utf8)?;
        let value = std::str::from_utf8(value).map_err(invalid_utf8)?;
        if let Some((_, existing)) = self.statuses.iter_mut().find(|(name, _)| name == key) {
            *existing = value.to_string();
        } else {
            self.statuses.push((key.to_string(), value.to_string()));
        }
        Ok(())
    }
}

fn validate_packet_length(length: usize) -> io::Result<()> {
    if !(4..=MAX_PACKET_LENGTH).contains(&length) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid PostgreSQL packet length {length}"),
        ));
    }
    Ok(())
}

fn invalid_utf8(error: std::str::Utf8Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

#[cfg(test)]
mod tests {
    use super::parse_startup_parameters;

    #[test]
    fn parses_startup_parameter_pairs() {
        let raw = [
            0, 0, 0, 41, 0, 3, 0, 0, b'u', b's', b'e', b'r', 0, b'p', b'o', b's', b't', b'g',
            b'r', b'e', b's', 0, b'd', b'a', b't', b'a', b'b', b'a', b's', b'e', 0, b'p', b'o',
            b's', b't', b'g', b'r', b'e', b's', 0, 0,
        ];
        let parameters = parse_startup_parameters(&raw).expect("startup parameters parse");
        assert_eq!(parameters.get("user"), Some(&"postgres".to_string()));
        assert_eq!(parameters.get("database"), Some(&"postgres".to_string()));
    }
}
