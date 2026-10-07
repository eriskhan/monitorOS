use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

pub const DEFAULT_CONTROL_BIND: &str = "[::]:5203";
pub const DEFAULT_BACKLIGHT_ROOT: &str = "/sys/class/backlight/acpi_video0";

const MESSAGE_MAGIC: &[u8; 8] = b"MOSBRT01";
const MESSAGE_SET_MAGIC: &[u8; 8] = b"MOSBRS01";
const MESSAGE_QUERY_MAGIC: &[u8; 8] = b"MOSBRQ01";
const MESSAGE_SIZE: usize = 9;
const RESPONSE_MAGIC: &[u8; 8] = b"MOSBRV01";
const VOLUME_SET_MAGIC: &[u8; 8] = b"MOSVLS01";
const VOLUME_RESPONSE_MAGIC: &[u8; 8] = b"MOSVLR01";
const MUTE_SET_MAGIC: &[u8; 8] = b"MOSMTS01";
const MUTE_RESPONSE_MAGIC: &[u8; 8] = b"MOSMTR01";
const RESPONSE_SIZE: usize = 9;
const COMMAND_BRIGHTNESS_DOWN: u8 = 1;
const COMMAND_BRIGHTNESS_UP: u8 = 2;
const COMMAND_BRIGHTNESS_FINE_DOWN: u8 = 3;
const COMMAND_BRIGHTNESS_FINE_UP: u8 = 4;
pub const BRIGHTNESS_FINE_STEPS: u32 = 64;
const BRIGHTNESS_COARSE_UNITS: u32 = 4;

// 13/64 = 20.3125%. The first native fine step above 20% is the crossover:
// unit 13 uses the panel's minimum physical backlight with unity shader output;
// units 0...12 keep that physical floor and dim in the Radeon GLES renderer.
pub const SOFTWARE_DIM_FLOOR_UNIT: u32 = 13;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BrightnessStep {
    Down,
    Up,
    FineDown,
    FineUp,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ControlRequest {
    BrightnessStep(BrightnessStep),
    SetBrightnessFineUnit(u32),
    QueryBrightness,
    SetVolumeUnit(u8),
    SetMute(bool),
}

pub struct ControlServer {
    _thread: JoinHandle<()>,
    brightness_read: OwnedFd,
    brightness_write: Arc<OwnedFd>,
    current_unit: Arc<Mutex<u8>>,
}

impl ControlServer {
    pub fn start(bind: &str, backlight_root: &Path) -> io::Result<Self> {
        let listener = TcpListener::bind(bind)?;
        let max_brightness = read_value(&backlight_root.join("max_brightness"))?;
        if max_brightness == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "backlight max_brightness must be greater than zero",
            ));
        }
        let raw_brightness = read_value(&backlight_root.join("brightness"))?;
        if raw_brightness > max_brightness {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "current brightness {raw_brightness} exceeds max_brightness {max_brightness}"
                ),
            ));
        }

        let initial_unit =
            raw_to_logical_unit(raw_brightness, max_brightness) as u8;
        let current_unit = Arc::new(Mutex::new(initial_unit));

        let mut pipe_fds = [-1_i32; 2];
        let pipe_result = unsafe {
            libc::pipe2(
                pipe_fds.as_mut_ptr(),
                libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if pipe_result != 0 {
            return Err(io::Error::last_os_error());
        }

        let brightness_read =
            unsafe { OwnedFd::from_raw_fd(pipe_fds[0]) };
        let brightness_write =
            Arc::new(unsafe { OwnedFd::from_raw_fd(pipe_fds[1]) });

        publish_output(brightness_write.as_raw_fd(), initial_unit)?;

        let backlight_root = backlight_root.to_path_buf();
        let thread_current = Arc::clone(&current_unit);
        let thread_write = Arc::clone(&brightness_write);

        println!(
            "monitorosd: control listening on {bind}; brightness_backend={} logical={}/{} physical={}/{} software_floor={}/{}",
            backlight_root.display(),
            initial_unit,
            BRIGHTNESS_FINE_STEPS,
            raw_brightness,
            max_brightness,
            SOFTWARE_DIM_FLOOR_UNIT,
            BRIGHTNESS_FINE_STEPS
        );

        let thread = thread::Builder::new()
            .name("monitoros-control".to_string())
            .spawn(move || {
                serve(
                    listener,
                    backlight_root,
                    max_brightness,
                    thread_current,
                    thread_write,
                )
            })?;

        Ok(Self {
            _thread: thread,
            brightness_read,
            brightness_write,
            current_unit,
        })
    }

    pub fn output_fd(&self) -> RawFd {
        self.brightness_read.as_raw_fd()
    }

    pub fn prepare_worker(&self) -> io::Result<()> {
        let current_unit = self
            .current_unit
            .lock()
            .map_err(|_| io::Error::other("brightness state lock poisoned"))?;

        let mut buffer = [0_u8; 256];
        loop {
            let read = unsafe {
                libc::read(
                    self.brightness_read.as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                )
            };
            if read > 0 {
                continue;
            }
            if read == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() == io::ErrorKind::WouldBlock {
                break;
            }
            return Err(error);
        }

        publish_output(
            self.brightness_write.as_raw_fd(),
            *current_unit,
        )
    }
}

fn serve(
    listener: TcpListener,
    backlight_root: PathBuf,
    max_brightness: u32,
    current_unit: Arc<Mutex<u8>>,
    brightness_write: Arc<OwnedFd>,
) {
    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                let client_backlight_root = backlight_root.clone();
                let client_current = Arc::clone(&current_unit);
                let client_write = Arc::clone(&brightness_write);
                if let Err(error) = thread::Builder::new()
                    .name("monitoros-control-client".to_string())
                    .spawn(move || {
                        if let Err(error) = handle_client(
                            stream,
                            &client_backlight_root,
                            max_brightness,
                            &client_current,
                            client_write.as_raw_fd(),
                        ) {
                            eprintln!(
                                "monitorosd: control client ended with error: {error}"
                            );
                        }
                    })
                {
                    eprintln!(
                        "monitorosd: control client thread failed: {error}"
                    );
                }
            }
            Err(error) => {
                eprintln!("monitorosd: control accept failed: {error}");
            }
        }
    }
}

fn handle_client(
    mut stream: TcpStream,
    backlight_root: &Path,
    max_brightness: u32,
    current_unit: &Mutex<u8>,
    brightness_output_fd: RawFd,
) -> io::Result<()> {
    println!(
        "monitorosd: control client connected from {}",
        stream.peer_addr()?
    );

    loop {
        let mut message = [0_u8; MESSAGE_SIZE];
        match stream.read_exact(&mut message) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                return Ok(());
            }
            Err(error) => return Err(error),
        }

        match parse_message(&message)? {
            ControlRequest::BrightnessStep(step) => {
                let mut current = current_unit.lock().map_err(|_| {
                    io::Error::other("brightness state lock poisoned")
                })?;
                let old_unit = u32::from(*current);
                let target_unit =
                    stepped_logical_brightness(old_unit, step);
                apply_unit(
                    backlight_root,
                    max_brightness,
                    old_unit,
                    target_unit,
                )?;
                *current = target_unit as u8;
                publish_output(brightness_output_fd, target_unit as u8)?;
                drop(current);
                write_response(&mut stream, RESPONSE_MAGIC, target_unit as u8)?;
            }
            ControlRequest::SetBrightnessFineUnit(target_unit) => {
                let mut current = current_unit.lock().map_err(|_| {
                    io::Error::other("brightness state lock poisoned")
                })?;
                let old_unit = u32::from(*current);
                apply_unit(
                    backlight_root,
                    max_brightness,
                    old_unit,
                    target_unit,
                )?;
                *current = target_unit as u8;
                publish_output(brightness_output_fd, target_unit as u8)?;
                drop(current);
                write_response(&mut stream, RESPONSE_MAGIC, target_unit as u8)?;
            }
            ControlRequest::QueryBrightness => {
                let current = current_unit.lock().map_err(|_| {
                    io::Error::other("brightness state lock poisoned")
                })?;
                let unit = *current;
                drop(current);
                write_response(&mut stream, RESPONSE_MAGIC, unit)?;
            }
            ControlRequest::SetVolumeUnit(unit) => {
                apply_volume_unit(unit)?;
                write_response(&mut stream, VOLUME_RESPONSE_MAGIC, unit)?;
            }
            ControlRequest::SetMute(muted) => {
                apply_mute(muted)?;
                write_response(
                    &mut stream,
                    MUTE_RESPONSE_MAGIC,
                    u8::from(muted),
                )?;
            }
        }
    }
}

fn parse_message(
    message: &[u8; MESSAGE_SIZE],
) -> io::Result<ControlRequest> {
    if &message[..MESSAGE_MAGIC.len()] == MESSAGE_MAGIC {
        let step = match message[MESSAGE_MAGIC.len()] {
            COMMAND_BRIGHTNESS_DOWN => BrightnessStep::Down,
            COMMAND_BRIGHTNESS_UP => BrightnessStep::Up,
            COMMAND_BRIGHTNESS_FINE_DOWN => BrightnessStep::FineDown,
            COMMAND_BRIGHTNESS_FINE_UP => BrightnessStep::FineUp,
            command => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unknown brightness command {command}"),
                ))
            }
        };
        return Ok(ControlRequest::BrightnessStep(step));
    }

    if &message[..MESSAGE_SET_MAGIC.len()] == MESSAGE_SET_MAGIC {
        let fine_unit = u32::from(message[MESSAGE_SET_MAGIC.len()]);
        if fine_unit > BRIGHTNESS_FINE_STEPS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "brightness fine unit {fine_unit} exceeds {BRIGHTNESS_FINE_STEPS}"
                ),
            ));
        }
        return Ok(ControlRequest::SetBrightnessFineUnit(fine_unit));
    }

    if &message[..MESSAGE_QUERY_MAGIC.len()] == MESSAGE_QUERY_MAGIC {
        return Ok(ControlRequest::QueryBrightness);
    }

    if &message[..VOLUME_SET_MAGIC.len()] == VOLUME_SET_MAGIC {
        return Ok(ControlRequest::SetVolumeUnit(
            message[VOLUME_SET_MAGIC.len()],
        ));
    }

    if &message[..MUTE_SET_MAGIC.len()] == MUTE_SET_MAGIC {
        let muted = match message[MUTE_SET_MAGIC.len()] {
            0 => false,
            1 => true,
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid mute value {value}"),
                ))
            }
        };
        return Ok(ControlRequest::SetMute(muted));
    }

    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "invalid monitorOS control magic/version",
    ))
}

fn apply_unit(
    backlight_root: &Path,
    max_brightness: u32,
    old_unit: u32,
    target_unit: u32,
) -> io::Result<()> {
    if target_unit > BRIGHTNESS_FINE_STEPS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "brightness fine unit {target_unit} exceeds {BRIGHTNESS_FINE_STEPS}"
            ),
        ));
    }

    let brightness_path = backlight_root.join("brightness");
    let current_raw = read_value(&brightness_path)?;
    if current_raw > max_brightness {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "current brightness {current_raw} exceeds max_brightness {max_brightness}"
            ),
        ));
    }

    let target_raw = logical_unit_to_raw(target_unit, max_brightness);
    if target_raw != current_raw {
        write_value(&brightness_path, target_raw)?;
    }

    let software_scale = software_scale_for_unit(target_unit);
    println!(
        "monitorosd: brightness logical {old_unit} -> {target_unit}/{} physical {current_raw} -> {target_raw}/{max_brightness} software_scale={software_scale:.4}",
        BRIGHTNESS_FINE_STEPS
    );
    Ok(())
}

fn stepped_logical_brightness(
    current_unit: u32,
    step: BrightnessStep,
) -> u32 {
    let delta = match step {
        BrightnessStep::Down | BrightnessStep::Up => {
            BRIGHTNESS_COARSE_UNITS
        }
        BrightnessStep::FineDown | BrightnessStep::FineUp => 1,
    };

    match step {
        BrightnessStep::Down | BrightnessStep::FineDown => {
            current_unit.saturating_sub(delta)
        }
        BrightnessStep::Up | BrightnessStep::FineUp => {
            current_unit
                .saturating_add(delta)
                .min(BRIGHTNESS_FINE_STEPS)
        }
    }
}

fn raw_to_logical_unit(raw: u32, max_brightness: u32) -> u32 {
    if raw == 0 {
        return SOFTWARE_DIM_FLOOR_UNIT;
    }

    let physical_units =
        BRIGHTNESS_FINE_STEPS - SOFTWARE_DIM_FLOOR_UNIT;
    SOFTWARE_DIM_FLOOR_UNIT
        + ((u64::from(raw) * u64::from(physical_units)
            + u64::from(max_brightness) / 2)
            / u64::from(max_brightness)) as u32
}

fn logical_unit_to_raw(unit: u32, max_brightness: u32) -> u32 {
    if unit <= SOFTWARE_DIM_FLOOR_UNIT {
        return 0;
    }

    let physical_units =
        BRIGHTNESS_FINE_STEPS - SOFTWARE_DIM_FLOOR_UNIT;
    ((u64::from(unit - SOFTWARE_DIM_FLOOR_UNIT)
        * u64::from(max_brightness)
        + u64::from(physical_units) / 2)
        / u64::from(physical_units)) as u32
}

fn software_scale_for_unit(unit: u32) -> f64 {
    if unit >= SOFTWARE_DIM_FLOOR_UNIT {
        1.0
    } else {
        f64::from(unit) / f64::from(SOFTWARE_DIM_FLOOR_UNIT)
    }
}

fn publish_output(fd: RawFd, fine_unit: u8) -> io::Result<()> {
    let byte = [fine_unit];
    let written = unsafe {
        libc::write(
            fd,
            byte.as_ptr().cast(),
            byte.len(),
        )
    };
    if written == 1 {
        return Ok(());
    }
    if written < 0 {
        let error = io::Error::last_os_error();
        if matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
        ) {
            return Ok(());
        }
        return Err(error);
    }

    Err(io::Error::new(
        io::ErrorKind::WriteZero,
        "brightness output pipe short write",
    ))
}

fn write_response(
    stream: &mut impl Write,
    magic: &[u8; 8],
    value: u8,
) -> io::Result<()> {
    let mut response = [0_u8; RESPONSE_SIZE];
    response[..magic.len()].copy_from_slice(magic);
    response[magic.len()] = value;
    stream.write_all(&response)
}

fn apply_volume_unit(unit: u8) -> io::Result<()> {
    let scalar = volume_scalar(unit);
    run_wpctl(&[
        "set-volume",
        "@DEFAULT_AUDIO_SINK@",
        scalar.as_str(),
    ])?;
    println!(
        "monitorosd: speaker volume {unit}/255 ({scalar})"
    );
    Ok(())
}

fn apply_mute(muted: bool) -> io::Result<()> {
    let value = if muted { "1" } else { "0" };
    run_wpctl(&["set-mute", "@DEFAULT_AUDIO_SINK@", value])?;
    println!("monitorosd: speaker mute={muted}");
    Ok(())
}

fn volume_scalar(unit: u8) -> String {
    format!("{:.6}", f64::from(unit) / 255.0)
}

fn run_wpctl(args: &[&str]) -> io::Result<()> {
    let output = Command::new("wpctl").args(args).output()?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(io::Error::other(format!(
        "wpctl {} failed with {}: {}",
        args.join(" "),
        output.status,
        stderr.trim()
    )))
}

fn read_value(path: &Path) -> io::Result<u32> {
    let value = fs::read_to_string(path)?;
    value.trim().parse::<u32>().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid integer in {}: {error}", path.display()),
        )
    })
}

fn write_value(path: &Path, value: u32) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).open(path)?;
    write_sysfs_value(&mut file, value).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("write {} failed: {error}", path.display()),
        )
    })
}

fn write_sysfs_value(
    writer: &mut impl Write,
    value: u32,
) -> io::Result<()> {
    let text = value.to_string();
    let written = writer.write(text.as_bytes())?;
    if written != text.len() {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            format!(
                "short sysfs write: wrote {written} of {} bytes",
                text.len()
            ),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_accepts_steps_and_absolute_brightness() {
        let mut message = *b"MOSBRT01\x01";
        assert_eq!(
            parse_message(&message).unwrap(),
            ControlRequest::BrightnessStep(BrightnessStep::Down)
        );

        message[MESSAGE_MAGIC.len()] = COMMAND_BRIGHTNESS_UP;
        assert_eq!(
            parse_message(&message).unwrap(),
            ControlRequest::BrightnessStep(BrightnessStep::Up)
        );

        message[MESSAGE_MAGIC.len()] = COMMAND_BRIGHTNESS_FINE_DOWN;
        assert_eq!(
            parse_message(&message).unwrap(),
            ControlRequest::BrightnessStep(BrightnessStep::FineDown)
        );

        message[MESSAGE_MAGIC.len()] = COMMAND_BRIGHTNESS_FINE_UP;
        assert_eq!(
            parse_message(&message).unwrap(),
            ControlRequest::BrightnessStep(BrightnessStep::FineUp)
        );

        let mut set = *b"MOSBRS01\x25";
        assert_eq!(
            parse_message(&set).unwrap(),
            ControlRequest::SetBrightnessFineUnit(37)
        );
        set[MESSAGE_SET_MAGIC.len()] = 65;
        assert!(parse_message(&set).is_err());

        let query = *b"MOSBRQ01\x00";
        assert_eq!(
            parse_message(&query).unwrap(),
            ControlRequest::QueryBrightness
        );

        message[0] = b'X';
        assert!(parse_message(&message).is_err());
    }

    #[test]
    fn hybrid_mapping_uses_all_physical_levels_above_floor() {
        assert_eq!(logical_unit_to_raw(0, 79), 0);
        assert_eq!(logical_unit_to_raw(12, 79), 0);
        assert_eq!(
            logical_unit_to_raw(SOFTWARE_DIM_FLOOR_UNIT, 79),
            0
        );
        assert_eq!(logical_unit_to_raw(64, 79), 79);

        for raw in 1..=79 {
            let unit = raw_to_logical_unit(raw, 79);
            assert!(unit > SOFTWARE_DIM_FLOOR_UNIT);
            assert!(unit <= BRIGHTNESS_FINE_STEPS);
        }
    }

    #[test]
    fn native_steps_continue_through_software_range() {
        assert_eq!(
            stepped_logical_brightness(64, BrightnessStep::Down),
            60
        );
        assert_eq!(
            stepped_logical_brightness(13, BrightnessStep::Down),
            9
        );
        assert_eq!(
            stepped_logical_brightness(1, BrightnessStep::FineDown),
            0
        );
        assert_eq!(
            stepped_logical_brightness(0, BrightnessStep::FineUp),
            1
        );
        assert_eq!(
            stepped_logical_brightness(64, BrightnessStep::Up),
            64
        );
    }

    #[test]
    fn software_scale_is_identity_at_floor_and_zero_at_zero() {
        assert_eq!(software_scale_for_unit(0), 0.0);
        assert!(
            (software_scale_for_unit(SOFTWARE_DIM_FLOOR_UNIT) - 1.0)
                .abs()
                < f64::EPSILON
        );
        assert!(
            (software_scale_for_unit(6)
                - 6.0 / f64::from(SOFTWARE_DIM_FLOOR_UNIT))
                .abs()
                < f64::EPSILON
        );
    }

    #[test]
    fn brightness_response_contains_normalized_fine_unit() {
        let mut bytes = Vec::new();
        write_response(&mut bytes, RESPONSE_MAGIC, 37).unwrap();
        assert_eq!(bytes.len(), RESPONSE_SIZE);
        assert_eq!(&bytes[..RESPONSE_MAGIC.len()], RESPONSE_MAGIC);
        assert_eq!(bytes[RESPONSE_MAGIC.len()], 37);
    }

    #[test]
    fn protocol_accepts_volume_and_mute_controls() {
        let volume = *b"MOSVLS01\x99";
        assert_eq!(
            parse_message(&volume).unwrap(),
            ControlRequest::SetVolumeUnit(153)
        );
        assert_eq!(volume_scalar(153), "0.600000");
        assert_eq!(volume_scalar(0), "0.000000");
        assert_eq!(volume_scalar(255), "1.000000");

        let mute = *b"MOSMTS01\x01";
        assert_eq!(
            parse_message(&mute).unwrap(),
            ControlRequest::SetMute(true)
        );
        let unmute = *b"MOSMTS01\x00";
        assert_eq!(
            parse_message(&unmute).unwrap(),
            ControlRequest::SetMute(false)
        );

        let invalid_mute = *b"MOSMTS01\x02";
        assert!(parse_message(&invalid_mute).is_err());

        let mut response = Vec::new();
        write_response(&mut response, VOLUME_RESPONSE_MAGIC, 153).unwrap();
        assert_eq!(response, b"MOSVLR01\x99");
    }

    #[test]
    fn sysfs_value_is_sent_in_one_write_without_newline() {
        struct Recorder {
            calls: usize,
            bytes: Vec<u8>,
        }

        impl Write for Recorder {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                self.calls += 1;
                self.bytes.extend_from_slice(buf);
                Ok(buf.len())
            }

            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let mut recorder = Recorder {
            calls: 0,
            bytes: Vec::new(),
        };
        write_sysfs_value(&mut recorder, 74).unwrap();

        assert_eq!(recorder.calls, 1);
        assert_eq!(recorder.bytes, b"74");
    }
}
