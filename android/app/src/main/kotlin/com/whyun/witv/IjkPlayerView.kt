package com.example.witv_flutter

import android.content.Context
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer
import java.io.File
import android.os.Build
import android.util.Log

class IjkPlayerView(context: Context, private val url: String, private val decoderIndex: Int) : PlatformView {
    private val surfaceView: SurfaceView = SurfaceView(context)
    private var player: IjkMediaPlayer? = null

    init {
        // 加载IJKPlayer库
        IjkMediaPlayer.loadLibrariesOnce(null)
        IjkMediaPlayer.native_profileBegin("libijkplayer.so")

        // 创建播放器
        player = IjkMediaPlayer().apply {
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "overlay-format", IjkMediaPlayer.SDL_FCC_RV32.toLong())
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)   // 允许丢帧，保证流畅
            setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024 * 1024L)      // 1MB
            setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 3 * 1000 * 1000L) // 3秒

            // ---------- 解码器配置 ----------
            if (decoderIndex == 0) {
                // 硬解码 (MediaCodec)
                Log.i("IJKPlayer", "启用硬解码")
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)
            } else {
                // 软解码：彻底关闭硬解
                Log.i("IJKPlayer", "启用软解码")
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 0L)
                setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
                // 针对RTSP强制TCP
                setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")
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
