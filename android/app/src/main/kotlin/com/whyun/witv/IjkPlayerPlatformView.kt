package com.example.witv_flutter

import android.content.Context
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer
import android.util.Log

class IjkPlayerPlatformView(
    context: Context,
    private val url: String,
    private val decoderIndex: Int
) : PlatformView {
    private val surfaceView: SurfaceView = SurfaceView(context)
    private var player: IjkMediaPlayer? = null

    init {
        IjkMediaPlayer.loadLibrariesOnce(null)
        IjkMediaPlayer.native_profileBegin("libijkplayer.so")

        player = IjkMediaPlayer().apply {
            // ---------- 通用选项 ----------
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "overlay-format", IjkMediaPlayer.SDL_FCC_RV32.toLong())
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024 * 1024L)
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 1000 * 1000L)

            // ---------- 解码器配置 ----------
            if (decoderIndex == 0) {
                // 硬解码
                Log.i("IJKPlayerPlatform", "启用硬解码")
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)
            } else {
                // 软解码
                Log.i("IJKPlayerPlatform", "启用软解码")
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")
            }

            dataSource = url
            setSurface(surfaceView.holder.surface)
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
