package com.whyun.witv

import android.content.Context
import android.util.Log
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer

class IjkPlayerView(context: Context, private val url: String, private val decoderIndex: Int) : PlatformView {
    private val surfaceView: SurfaceView = SurfaceView(context)
    private var player: IjkMediaPlayer? = null

    init {
        IjkMediaPlayer.loadLibrariesOnce(null)
        IjkMediaPlayer.native_profileBegin("libijkplayer.so")

        player = IjkMediaPlayer().apply {
            // ---------- 通用选项 ----------
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
            // 【关键】强制使用 RGB 渲染格式，避免 YUV 转换花屏
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "overlay-format", IjkMediaPlayer.SDL_FCC_RV32.toLong())
            // 丢帧策略：1=轻度丢帧，5=重度丢帧，模拟器建议 1
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1L)
            // 立即渲染，不等待缓冲
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "render-wait-start", 0L)
            // 增大缓冲区，减少卡顿
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", 2 * 1024 * 1024L) // 2MB

            // ---------- 格式选项 ----------
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024 * 1024L)          // 1MB
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 1000 * 1000L)     // 1秒
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "flush_packets", 1L)                 // 立即刷新

            // ---------- 解码器配置 ----------
            if (decoderIndex == 0) {
                Log.i("IJKPlayer", "启用硬解码 (MediaCodec)")

                // 开启硬解
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
                // 明确支持 H.264 和 H.265
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)

                // 【重要】关闭自动旋转和分辨率变化处理，避免模拟器花屏
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 0L)

                // 增加解码超时（模拟器可能较慢）
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-timeout", 3000L)

                // 尝试使用更兼容的输出格式（可选）
                // setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-mpeg2", 1L)

            } else {
                Log.i("IJKPlayer", "启用软解码")
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
            }

            // 设置播放地址
            dataSource = url

            // 设置显示Surface
            setSurface(surfaceView.holder.surface)

            // 准备播放
            prepareAsync()
        }
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        player?.stop()
        player?.release()
        player = null
        IjkMediaPlayer.native_profileEnd()
    }
}
