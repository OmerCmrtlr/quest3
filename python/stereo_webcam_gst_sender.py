#!/usr/bin/env python3
"""
Laptop webcam -> GStreamer H264/RTP -> UDP -> Tablet/Quest receiver

Örnek:
  python3 stereo_webcam_gst_sender.py --device /dev/video0 --host 192.168.1.55 --port 5010
"""

import argparse
import math
import socket
import signal

try:
    import gi
    gi.require_version("Gst", "1.0")
    gi.require_version("GLib", "2.0")
    from gi.repository import Gst, GLib
except Exception as exc:
    print(f"[Sender] HATA: {exc}")
    print("Kurulum: sudo apt install python3-gi python3-gst-1.0 gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-libav")
    raise SystemExit(1)


class StereoGstSender:
    def __init__(self, device: str, host: str, port: int, width: int, height: int, fps: int, bitrate: int):
        self.device = device
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate

        self.pipeline = None
        self.loop = None

    def build_pipeline(self) -> str:
        return (
            f"v4l2src device={self.device} do-timestamp=true ! "
            "videoconvert ! videoscale ! videorate ! "
            f"video/x-raw,width={self.width},height={self.height},framerate={self.fps}/1,format=I420 ! "
            f"x264enc tune=zerolatency speed-preset=ultrafast bitrate={self.bitrate} key-int-max=30 ! "
            "rtph264pay pt=96 config-interval=1 ! "
            f"udpsink host={self.host} port={self.port} sync=false async=false"
        )

    def on_bus_message(self, _bus, message):
        if message.type == Gst.MessageType.ERROR:
            err, dbg = message.parse_error()
            print(f"[Sender] GST ERROR: {err} | {dbg}")
            self.stop()
        elif message.type == Gst.MessageType.EOS:
            print("[Sender] EOS")
            self.stop()

    def start(self) -> bool:
        Gst.init(None)
        pipeline_str = self.build_pipeline()
        print(f"[Sender] Pipeline: {pipeline_str}")

        try:
            self.pipeline = Gst.parse_launch(pipeline_str)
        except Exception as exc:
            print(f"[Sender] Pipeline parse hatası: {exc}")
            return False

        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self.on_bus_message)

        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            print("[Sender] PLAYING durumuna geçemedi")
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
            return False

        self.loop = GLib.MainLoop()
        print(f"[Sender] BAŞLADI -> {self.host}:{self.port} ({self.width}x{self.height}@{self.fps} {self.bitrate}kbps)")
        return True

    def run(self):
        if self.loop:
            self.loop.run()

    def stop(self):
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        if self.loop and self.loop.is_running():
            self.loop.quit()
        print("[Sender] DURDU")


class UdpJpegSender:
    """UDP + JPEG fallback sender (low latency, no native GStreamer receiver required on Android)."""

    def __init__(self, device: str, host: str, port: int, width: int, height: int, fps: int, jpeg_quality: int, mtu: int, max_frame_bytes: int):
        self.device = device
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.fps = fps
        self.jpeg_quality = max(20, min(95, jpeg_quality))
        self.mtu = max(512, min(1400, mtu))
        self.max_frame_bytes = max(200_000, max_frame_bytes)

        self.pipeline = None
        self.loop = None
        self.socket = None
        self.frame_id = 0

    def build_pipeline(self) -> str:
        return (
            f"v4l2src device={self.device} do-timestamp=true ! "
            "videoconvert ! videoscale ! videorate ! "
            f"video/x-raw,width={self.width},height={self.height},framerate={self.fps}/1,format=I420 ! "
            f"jpegenc quality={self.jpeg_quality} ! "
            "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )

    def on_bus_message(self, _bus, message):
        if message.type == Gst.MessageType.ERROR:
            err, dbg = message.parse_error()
            print(f"[UDP-JPEG] GST ERROR: {err} | {dbg}")
            self.stop()
        elif message.type == Gst.MessageType.EOS:
            print("[UDP-JPEG] EOS")
            self.stop()

    def _send_frame(self, frame_bytes: bytes) -> None:
        frame_len = len(frame_bytes)
        if frame_len <= 0:
            return
        if frame_len > self.max_frame_bytes:
            return

        header_size = 12
        payload_size = self.mtu - header_size
        if payload_size <= 0:
            return

        chunk_count = math.ceil(frame_len / payload_size)
        if chunk_count <= 0 or chunk_count > 65535:
            return

        frame_id = self.frame_id & 0xFFFFFFFF
        self.frame_id = (self.frame_id + 1) & 0xFFFFFFFF

        target = (self.host, self.port)
        for idx in range(chunk_count):
            start = idx * payload_size
            end = min(frame_len, start + payload_size)
            chunk = frame_bytes[start:end]

            header = (
                b"QJ"
                + frame_id.to_bytes(4, "big", signed=False)
                + idx.to_bytes(2, "big", signed=False)
                + chunk_count.to_bytes(2, "big", signed=False)
                + len(chunk).to_bytes(2, "big", signed=False)
            )
            self.socket.sendto(header + chunk, target)

    def on_new_sample(self, sink):
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK

        buffer = sample.get_buffer()
        if buffer is None:
            return Gst.FlowReturn.OK

        ok, map_info = buffer.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK

        try:
            self._send_frame(bytes(map_info.data))
        finally:
            buffer.unmap(map_info)

        return Gst.FlowReturn.OK

    def start(self) -> bool:
        Gst.init(None)
        pipeline_str = self.build_pipeline()
        print(f"[UDP-JPEG] Pipeline: {pipeline_str}")

        try:
            self.pipeline = Gst.parse_launch(pipeline_str)
        except Exception as exc:
            print(f"[UDP-JPEG] Pipeline parse hatası: {exc}")
            return False

        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)

        sink = self.pipeline.get_by_name("sink")
        if sink is None:
            print("[UDP-JPEG] appsink bulunamadı")
            return False

        sink.connect("new-sample", self.on_new_sample)

        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self.on_bus_message)

        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            print("[UDP-JPEG] PLAYING durumuna geçemedi")
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
            return False

        self.loop = GLib.MainLoop()
        print(f"[UDP-JPEG] BAŞLADI -> {self.host}:{self.port} ({self.width}x{self.height}@{self.fps}, q={self.jpeg_quality}, mtu={self.mtu})")
        return True

    def run(self):
        if self.loop:
            self.loop.run()

    def stop(self):
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        if self.socket:
            self.socket.close()
            self.socket = None
        if self.loop and self.loop.is_running():
            self.loop.quit()
        print("[UDP-JPEG] DURDU")


def main() -> int:
    parser = argparse.ArgumentParser(description="Stereo webcam gstreamer sender")
    parser.add_argument("--device", default="/dev/video0")
    parser.add_argument("--host", required=True, help="Tablet/Quest IP adresi")
    parser.add_argument("--port", type=int, default=5010)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--bitrate", type=int, default=2000)
    parser.add_argument("--mode", choices=["udp-jpeg", "gst-rtp"], default="udp-jpeg")
    parser.add_argument("--jpeg-quality", type=int, default=60)
    parser.add_argument("--mtu", type=int, default=1200)
    parser.add_argument("--max-frame-bytes", type=int, default=4000000)
    args = parser.parse_args()

    if args.mode == "gst-rtp":
        sender = StereoGstSender(
            device=args.device,
            host=args.host,
            port=args.port,
            width=args.width,
            height=args.height,
            fps=args.fps,
            bitrate=args.bitrate,
        )
    else:
        sender = UdpJpegSender(
            device=args.device,
            host=args.host,
            port=args.port,
            width=args.width,
            height=args.height,
            fps=args.fps,
            jpeg_quality=args.jpeg_quality,
            mtu=args.mtu,
            max_frame_bytes=args.max_frame_bytes,
        )

    if not sender.start():
        return 1

    signal.signal(signal.SIGINT, lambda *_: sender.stop())
    signal.signal(signal.SIGTERM, lambda *_: sender.stop())
    sender.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
