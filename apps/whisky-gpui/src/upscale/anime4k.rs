//! Anime4K CNN x2 S on Metal compute.
//!
//! The network is the same one the Wine GDI presenter runs, translated to Metal
//! by the sibling repository's `generate-anime4k-metal.py`: four 3x3 convolutions
//! over RGBA feature pairs plus a depth-to-space pass that samples the original
//! bilinearly and adds the residual. Weights are baked into the shader, so there
//! is no model file to ship or download.
//!
//! Everything here stays on the thread that built it: Metal objects are not
//! `Send`, and the pipelines are per-thread so a worker never has to share them.

use metal::*;
use std::cell::RefCell;

const KERNELS: [&str; 5] = [
    "convolution0",
    "convolution1",
    "convolution2",
    "convolution3",
    "depth_to_space",
];

const SHADER: &str = include_str!("anime4k.metal");

/// Thread group that maps onto one 8x8 output block; the kernels clamp their own
/// reads, so the grid does not need padding.
const GROUP: u64 = 8;

struct Pipelines {
    device: Device,
    queue: CommandQueue,
    kernels: [ComputePipelineState; 5],
}

thread_local! {
    static PIPELINES: RefCell<Option<Option<Pipelines>>> = const { RefCell::new(None) };
}

/// Doubles the image. `rgba` must be `width * height * 4` bytes.
pub(super) fn upscale_x2(rgba: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || rgba.len() != (width as usize) * (height as usize) * 4 {
        return None;
    }
    PIPELINES.with(|slot| {
        let mut slot = slot.borrow_mut();
        if slot.is_none() {
            *slot = Some(Pipelines::new());
        }
        match slot.as_ref() {
            Some(Some(pipelines)) => pipelines.run(rgba, width, height),
            _ => None,
        }
    })
}

impl Pipelines {
    fn new() -> Option<Self> {
        let device = Device::system_default()?;
        let queue = device.new_command_queue();
        let library = device.new_library_with_source(SHADER, &CompileOptions::new()).ok()?;
        let mut states = Vec::with_capacity(KERNELS.len());
        for name in KERNELS {
            let function = library.get_function(name, None).ok()?;
            states.push(device.new_compute_pipeline_state_with_function(&function).ok()?);
        }
        Some(Self {
            device,
            queue,
            kernels: states.try_into().ok()?,
        })
    }

    fn run(&self, rgba: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
        let (w, h) = (u64::from(width), u64::from(height));
        let source = self.upload(rgba, w, h)?;
        // Ping-pong between two feature textures: each convolution reads the
        // previous one and writes the other.
        let first = self.scratch(w, h)?;
        let second = self.scratch(w, h)?;
        let output = self.scratch(w * 2, h * 2)?;

        let command = self.queue.new_command_buffer();
        self.dispatch(command, 0, &source, &first, w, h);
        self.dispatch(command, 1, &first, &second, w, h);
        self.dispatch(command, 2, &second, &first, w, h);
        self.dispatch(command, 3, &first, &second, w, h);
        {
            let encoder = command.new_compute_command_encoder();
            encoder.set_compute_pipeline_state(&self.kernels[4]);
            encoder.set_texture(0, Some(&second));
            encoder.set_texture(1, Some(&source));
            encoder.set_texture(2, Some(&output));
            encoder.dispatch_threads(
                MTLSize::new(w * 2, h * 2, 1),
                MTLSize::new(GROUP, GROUP, 1),
            );
            encoder.end_encoding();
        }
        command.commit();
        command.wait_until_completed();

        let (out_w, out_h) = (w * 2, h * 2);
        let mut floats = vec![0_f32; (out_w * out_h * 4) as usize];
        output.get_bytes(
            floats.as_mut_ptr().cast(),
            out_w * 16,
            MTLRegion::new_2d(0, 0, out_w, out_h),
            0,
        );
        let mut bytes = Vec::with_capacity(floats.len());
        for value in floats {
            // The depth-to-space pass already clamps; rounding here keeps a
            // flat area flat instead of drifting by one level.
            bytes.push((value.clamp(0., 1.) * 255.).round() as u8);
        }
        Some(bytes)
    }

    fn dispatch(
        &self,
        command: &CommandBufferRef,
        kernel: usize,
        from: &TextureRef,
        to: &TextureRef,
        width: u64,
        height: u64,
    ) {
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.kernels[kernel]);
        encoder.set_texture(0, Some(from));
        encoder.set_texture(1, Some(to));
        encoder.dispatch_threads(MTLSize::new(width, height, 1), MTLSize::new(GROUP, GROUP, 1));
        encoder.end_encoding();
    }

    /// The cover as the network reads it: the unorm texture keeps the file's
    /// own bytes, and `access::read` hands the kernel floats in 0...1.
    fn upload(&self, rgba: &[u8], width: u64, height: u64) -> Option<Texture> {
        let texture = self.texture(MTLPixelFormat::RGBA8Unorm, width, height)?;
        texture.replace_region(
            MTLRegion::new_2d(0, 0, width, height),
            0,
            rgba.as_ptr().cast(),
            width * 4,
        );
        Some(texture)
    }

    fn scratch(&self, width: u64, height: u64) -> Option<Texture> {
        self.texture(MTLPixelFormat::RGBA32Float, width, height)
    }

    fn texture(&self, format: MTLPixelFormat, width: u64, height: u64) -> Option<Texture> {
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(format);
        descriptor.set_width(width);
        descriptor.set_height(height);
        descriptor.set_usage(MTLTextureUsage::ShaderRead.union(MTLTextureUsage::ShaderWrite));
        // Shared storage is what `get_bytes` can read back on Apple silicon.
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        Some(self.device.new_texture(&descriptor))
    }
}
