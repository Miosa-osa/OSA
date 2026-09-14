use crate::frame::Frame;
use anyhow::{ensure, Context, Result};
use gstreamer::{self as gst, prelude::*};
use gstreamer_app as gst_app;
use gstreamer_video::{self as gst_video, prelude::*};
use std::{
    os::fd::{AsRawFd, OwnedFd},
    sync::Arc,
};
use tokio::sync::watch;

/// Owns the portal-supplied connection for the complete pipeline lifetime.
pub struct Capture {
    pipeline: gst::Pipeline,
    _remote: OwnedFd,
}

impl Capture {
    pub fn preflight() -> Result<()> {
        gst::init()?;
        for name in ["pipewiresrc", "videoconvert", "appsink"] {
            ensure!(
                gst::ElementFactory::find(name).is_some(),
                "missing_gstreamer_element: {name}"
            );
        }
        Ok(())
    }

    pub fn start(
        remote: OwnedFd,
        node: u32,
        frames: watch::Sender<Option<Arc<Frame>>>,
    ) -> Result<Self> {
        gst::init()?;
        let source = gst::ElementFactory::make("pipewiresrc")
            .property("fd", remote.as_raw_fd())
            .property("path", node.to_string())
            .property("do-timestamp", true)
            .build()
            .context("pipewiresrc_missing")?;
        let convert = gst::ElementFactory::make("videoconvert").build()?;
        let sink = gst_app::AppSink::builder()
            .caps(
                &gst::Caps::builder("video/x-raw")
                    .field("format", "BGRx")
                    .build(),
            )
            .max_buffers(1)
            .drop(true)
            .sync(false)
            .build();
        sink.set_callbacks(
            gst_app::AppSinkCallbacks::builder()
                .new_sample(move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    let frame = sample_frame(&sample).map_err(|_| gst::FlowError::Error)?;
                    frames.send_replace(Some(Arc::new(frame)));
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );
        let pipeline = gst::Pipeline::new();
        pipeline.add_many([&source, &convert, sink.upcast_ref()])?;
        gst::Element::link_many([&source, &convert, sink.upcast_ref()])?;
        let capture = Self {
            pipeline,
            _remote: remote,
        };
        capture.pipeline.set_state(gst::State::Playing)?;
        Ok(capture)
    }

    /// A bus error or EOS invalidates the session; never replay stale frames.
    pub fn check(&self) -> Result<()> {
        let bus = self.pipeline.bus().context("capture_bus_missing")?;
        for message in bus.iter() {
            match message.view() {
                gst::MessageView::Error(_) => anyhow::bail!("pipewire_capture_failed"),
                gst::MessageView::Eos(_) => anyhow::bail!("pipewire_capture_ended"),
                _ => {}
            }
        }
        Ok(())
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

fn sample_frame(sample: &gst::Sample) -> Result<Frame> {
    let info = gst_video::VideoInfo::from_caps(sample.caps().context("missing_caps")?)?;
    ensure!(
        info.format() == gst_video::VideoFormat::Bgrx,
        "unsupported_capture_format"
    );
    let frame = gst_video::VideoFrameRef::from_buffer_ref_readable(
        sample.buffer().context("missing_buffer")?,
        &info,
    )?;
    let stride = usize::try_from(frame.plane_stride()[0]).context("negative_stride")?;
    Frame::from_bgrx(info.width(), info.height(), stride, frame.plane_data(0)?)
}
