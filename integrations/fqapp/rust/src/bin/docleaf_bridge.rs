use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Body;
use axum::extract::Request;
use axum::http::{header, HeaderValue, Method, StatusCode};
use axum::response::Response;
use axum::Router;
use url::Url;

const BRIDGE_PORT: u16 = 8787;
const ALLOWED_ORIGINS: [&str; 4] = [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://localhost:3001",
    "http://127.0.0.1:3001",
];

fn with_cors(mut response: Response, origin: Option<&str>) -> Response {
    if let Some(origin) = origin.filter(|value| ALLOWED_ORIGINS.contains(value)) {
        if let Ok(value) = HeaderValue::from_str(origin) {
            response
                .headers_mut()
                .insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
        }
    }
    response.headers_mut().insert(
        header::ACCESS_CONTROL_ALLOW_METHODS,
        HeaderValue::from_static("GET, OPTIONS"),
    );
    response.headers_mut().insert(
        header::ACCESS_CONTROL_ALLOW_HEADERS,
        HeaderValue::from_static("Content-Type"),
    );
    response
}

fn plain(status: StatusCode, body: impl Into<Body>, origin: Option<&str>) -> Response {
    let response = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
        .body(body.into())
        .unwrap_or_else(|_| Response::new(Body::empty()));
    with_cors(response, origin)
}

fn sniff_image_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") { return Some("image/png"); }
    if bytes.starts_with(b"\xff\xd8\xff") { return Some("image/jpeg"); }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") { return Some("image/gif"); }
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" { return Some("image/webp"); }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        return match &bytes[8..12] {
            b"avif" | b"avis" => Some("image/avif"),
            b"heic" | b"heix" | b"hevc" | b"hevx" | b"mif1" | b"msf1" => Some("image/heic"),
            _ => None,
        };
    }
    None
}

fn convert_heic_for_browser(bytes: &[u8]) -> Option<Vec<u8>> {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_nanos();
    let base = std::env::temp_dir().join(format!("docleaf-comment-{}-{stamp}", std::process::id()));
    let input = base.with_extension("heic");
    let output = base.with_extension("png");
    std::fs::write(&input, bytes).ok()?;
    let converted = std::process::Command::new("sips")
        .args(["-s", "format", "png"])
        .arg(&input)
        .args(["--out"])
        .arg(&output)
        .output()
        .ok()
        .filter(|result| result.status.success())
        .and_then(|_| std::fs::read(&output).ok());
    let _ = std::fs::remove_file(input);
    let _ = std::fs::remove_file(output);
    converted
}

async fn image_proxy(uri: &axum::http::Uri, origin: Option<&str>) -> Response {
    let source = uri
        .query()
        .and_then(|query| url::form_urlencoded::parse(query.as_bytes()).find(|(key, _)| key == "url"))
        .map(|(_, value)| value.into_owned());
    let Some(source) = source else {
        return plain(StatusCode::BAD_REQUEST, r#"{"success":false,"message":"missing image url"}"#, origin);
    };
    let Ok(parsed) = Url::parse(&source) else {
        return plain(StatusCode::BAD_REQUEST, r#"{"success":false,"message":"invalid image url"}"#, origin);
    };
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return plain(StatusCode::BAD_REQUEST, r#"{"success":false,"message":"unsupported image url"}"#, origin);
    }
    let client = match reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::limited(5))
        .timeout(std::time::Duration::from_secs(20))
        .build()
    {
        Ok(client) => client,
        Err(error) => return plain(StatusCode::BAD_GATEWAY, error.to_string(), origin),
    };
    // ByteDance uses several image CDNs with different hot-link policies.
    // Try the address as-is first (the app normally sends no Referer), then
    // retry with the two known web origins used by Fanqie/Toutiao.
    let mut upstream = None;
    let mut last_error = "image upstream rejected the request".to_string();
    for referer in [None, Some("https://fanqienovel.com/"), Some("https://www.toutiao.com/")] {
        let mut request = client
            .get(parsed.clone())
            .header(header::USER_AGENT, "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36")
            .header(header::ACCEPT, "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8");
        if let Some(value) = referer {
            request = request.header(header::REFERER, value);
        }
        match request.send().await {
            Ok(response) if response.status().is_success() => {
                upstream = Some(response);
                break;
            }
            Ok(response) => last_error = format!("image upstream status {}", response.status()),
            Err(error) => last_error = error.to_string(),
        }
    }
    let Some(upstream) = upstream else {
        eprintln!("comment image proxy failed for {}: {}", parsed.host_str().unwrap_or("unknown"), last_error);
        return plain(StatusCode::BAD_GATEWAY, last_error, origin);
    };
    if upstream.content_length().unwrap_or(0) > 15 * 1024 * 1024 {
        return plain(StatusCode::PAYLOAD_TOO_LARGE, "image too large", origin);
    }
    let declared_type = upstream.headers().get(header::CONTENT_TYPE).and_then(|value| value.to_str().ok()).unwrap_or("").to_string();
    let mut bytes = match upstream.bytes().await {
        Ok(bytes) if bytes.len() <= 15 * 1024 * 1024 => bytes.to_vec(),
        Ok(_) => return plain(StatusCode::PAYLOAD_TOO_LARGE, "image too large", origin),
        Err(error) => return plain(StatusCode::BAD_GATEWAY, error.to_string(), origin),
    };
    let mut detected_type = sniff_image_type(&bytes);
    if detected_type == Some("image/heic") {
        if let Some(png) = convert_heic_for_browser(&bytes) {
            bytes = png;
            detected_type = Some("image/png");
        }
    }
    let Some(content_type) = detected_type else {
        eprintln!("comment image returned non-image data from {}: type={}, bytes={}", parsed.host_str().unwrap_or("unknown"), declared_type, bytes.len());
        return plain(StatusCode::BAD_GATEWAY, "upstream did not return a supported image", origin);
    };
    let response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CACHE_CONTROL, "private, max-age=86400")
        .body(Body::from(bytes))
        .unwrap_or_else(|_| Response::new(Body::empty()));
    with_cors(response, origin)
}

async fn bridge(req: Request) -> Response {
    let origin = req
        .headers()
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let origin_ref = origin.as_deref();
    if let Some(value) = origin_ref {
        if !ALLOWED_ORIGINS.contains(&value) {
            return plain(
                StatusCode::FORBIDDEN,
                r#"{"success":false,"message":"origin not allowed"}"#,
                None,
            );
        }
    }
    if req.method() == Method::OPTIONS {
        return with_cors(Response::new(Body::empty()), origin_ref);
    }
    if req.method() != Method::GET {
        return plain(
            StatusCode::METHOD_NOT_ALLOWED,
            r#"{"success":false,"message":"GET only"}"#,
            origin_ref,
        );
    }
    let uri = req.uri().clone();
    if uri.path() == "/health" {
        return plain(
            StatusCode::OK,
            r#"{"success":true,"service":"docleaf-fqapp-bridge"}"#,
            origin_ref,
        );
    }
    if uri.path() == "/image" {
        return image_proxy(&uri, origin_ref).await;
    }
    if !uri.path().starts_with("/api/") {
        return plain(
            StatusCode::NOT_FOUND,
            r#"{"success":false,"message":"not found"}"#,
            origin_ref,
        );
    }
    let request_id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos().to_string())
        .unwrap_or_default();
    match fqapi_core::api::request(
        request_id,
        "GET".to_string(),
        uri.path().to_string(),
        uri.query().unwrap_or("").to_string(),
        Vec::new(),
        45_000,
    )
    .await
    {
        Ok(result) => {
            let response = Response::builder()
                .status(result.status)
                .header(header::CONTENT_TYPE, result.content_type)
                .body(Body::from(result.body))
                .unwrap_or_else(|_| Response::new(Body::empty()));
            with_cors(response, origin_ref)
        }
        Err(error) => plain(
            StatusCode::BAD_GATEWAY,
            format!(
                r#"{{"success":false,"message":{}}}"#,
                serde_json::to_string(&error).unwrap_or_else(|_| "\"bridge error\"".to_string())
            ),
            origin_ref,
        ),
    }
}

fn ensure_pool(example: &Path, pool: &Path) -> Result<(), String> {
    if pool.exists() {
        return Ok(());
    }
    if let Some(parent) = pool.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::copy(example, pool)
        .map(|_| ())
        .map_err(|error| format!("seed device pool: {error}"))
}

#[tokio::main]
async fn main() -> Result<(), String> {
    let packaged_dir = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .filter(|path| path.join("assets/config/config.json").is_file());
    let fqapp_dir = if let Some(path) = packaged_dir {
        path
    } else {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .ok_or_else(|| "invalid fqapp path".to_string())?
            .to_path_buf()
    };
    let assets = fqapp_dir.join("assets");
    let data = fqapp_dir.join(".docleaf-data");
    let pool = data.join("device_pool.json");
    ensure_pool(&assets.join("config/device_pool.example.json"), &pool)?;
    fqapi_core::api::init(
        assets
            .join("config/config.json")
            .to_string_lossy()
            .into_owned(),
        pool.to_string_lossy().into_owned(),
        assets
            .join("config/filter.json")
            .to_string_lossy()
            .into_owned(),
        assets.to_string_lossy().into_owned(),
        0,
        String::new(),
    )
    .await?;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", BRIDGE_PORT))
        .await
        .map_err(|error| format!("listen 127.0.0.1:{BRIDGE_PORT}: {error}"))?;
    println!("DocLeaf 番茄书源已启动：http://127.0.0.1:{BRIDGE_PORT}");
    axum::serve(listener, Router::new().fallback(bridge))
        .await
        .map_err(|error| error.to_string())
}
