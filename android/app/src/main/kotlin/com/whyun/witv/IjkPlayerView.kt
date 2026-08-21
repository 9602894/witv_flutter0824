package com.whyun.witv

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer

class IjkPlayerView(
    context: Context,
    id: Int,
    creationParams: Map<String?, Any?>?,
    messenger: BinaryMessenger
) : PlatformView {

    private val surfaceView: SurfaceView = SurfaceView(context)
    private var ijkMediaPlayer: IjkMediaPlayer? = null
    private val methodChannel: MethodChannel = MethodChannel(messenger, "ijkplayer_view_$id")
    private var pendingUrl: String? = null
    private var isSurfaceReady = false
    private var currentUrl: String? = null
    private var decoderIndex: Int = 0

    init {
        decoderIndex = (creationParams?.get("decoderIndex") as? Int) ?: 0

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setUrl" -> {
                    val url = call.argument<String>("url")
                    val newDecoderIndex = call.argument<Int>("decoderIndex")
                    if (newDecoderIndex != null && newDecoderIndex != decoderIndex) {
                        decoderIndex = newDecoderIndex
                    }
                    if (url != null && url != currentUrl) {
                        currentUrl = url
                        if (isSurfaceReady) {
                            setUrl(url)
                        } else {
                            pendingUrl = url
                        }
                    }
                    result.success(null)
                }
                "release" -> {
                    releasePlayer()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                isSurfaceReady = true
                ijkMediaPlayer?.setDisplay(holder)
                pendingUrl?.let {
                    setUrl(it)
                    pendingUrl = null
                }
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                isSurfaceReady = false
                ijkMediaPlayer?.setDisplay(null)
            }
        })
    }

    private fun createPlayer(): IjkMediaPlayer {
        val player = IjkMediaPlayer()

        // ============================================================
        // 【关键】Format 级别参数 —— 必须在 setDataSource 之前设置
        // ============================================================

        // 探测大小：从默认 5MB 降到 512KB，换台速度提升最明显
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 512 * 1024L)

        // 分析时长：从默认 5秒 降到 500ms
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 500 * 1000L)

        // 断线自动重连
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_at_eof", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_streamed", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect_delay_max", 5L)

        // 网络超时 10秒，DNS 缓存清理
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", 10 * 1000 * 1000L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_clear", 1L)

        // fastseek
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek")

        // 协议白名单
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "protocol_whitelist",
            "file,http,https,tcp,tls,crypto,rtsp,rtp,udp,rtmp,rtmps,rtmpt,rtmpts"
        )

        // ============================================================
        // Player 级别参数
        // ============================================================

        // 首帧等待：从默认 3 帧降到 1 帧
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 1L)

        // 启动即播放
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        // 缓冲
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", 15 * 1024 * 1024L)

        // 精准 Seek
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "enable-accurate-seek", 1L)

        // 音频
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "soundtouch", 1L)

        // ============================================================
        // 解码器分支
        // ============================================================
        if (decoderIndex == 0) {
            // 硬解
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "skip_loop_filter", 48L)
        } else {
            // 软解
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "threads", 4L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "skip_loop_filter", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)
        }

        // 回调
        player.setOnPreparedListener {
            player.start()
            methodChannel.invokeMethod("onInfo", mapOf("what" to 3))
        }

        player.setOnErrorListener { _, what, extra ->
            methodChannel.invokeMethod("onError", mapOf("what" to what, "extra" to extra))
            true
        }

        player.setOnInfoListener { _, what, extra ->
            methodChannel.invokeMethod("onInfo", mapOf("what" to what, "extra" to extra))
            true
        }

        return player
    }

    /**
     * 每次换台都新建播放器（避免 reset() 带来的状态问题）
     * SurfaceView 保持复用，只换播放器内核
     */
    private fun setUrl(url: String) {
        releasePlayer()

        val player = createPlayer()
        ijkMediaPlayer = player

        if (isSurfaceReady) {
            player.setDisplay(surfaceView.holder)
        }

        try {
            player.dataSource = url
            player.prepareAsync()
        } catch (e: Exception) {
            methodChannel.invokeMethod("onError", mapOf("what" to -1, "extra" to e.message))
        }
    }

    private fun releasePlayer() {
        ijkMediaPlayer?.let {
            try {
                it.stop()
                it.setDisplay(null)
                it.release()
            } catch (_: Exception) {}
        }
        ijkMediaPlayer = null
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        releasePlayer()
    }
}
