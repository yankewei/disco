use disco_protocol::ToolResponse;
use disco_tool_runtime::execute;
use std::error::Error;
use std::io::{self, BufRead, Write};

const MAX_FRAME_BYTES: usize = 1_048_576;

fn main() -> Result<(), Box<dyn Error>> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());

    for line in stdin.lock().lines() {
        let line = line?;
        let response = if line.len() > MAX_FRAME_BYTES {
            ToolResponse::failure("unknown", "frame_too_large", "request frame exceeds 1 MiB")
        } else {
            match serde_json::from_str(&line) {
                Ok(request) => execute(request),
                Err(error) => ToolResponse::failure(
                    "unknown",
                    "invalid_request",
                    format!("request is not valid JSON: {error}"),
                ),
            }
        };
        serde_json::to_writer(&mut stdout, &response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }
    Ok(())
}
