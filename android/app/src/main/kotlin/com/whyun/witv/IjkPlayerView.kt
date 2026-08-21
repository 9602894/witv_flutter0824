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
    private var isPlayerError: Boolean = false

    init {
        decoderIndex = (creationParams?.get("decoderIndex") as? Int) ?: 0

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setUrl" -> {
                    val url = call.argument<String>("url")
                    val newDecoderIndex = call.argument<Int>("decoderIndex")
                    val needRecreate = newDecoderIndex != null && newDecoderIndex != decoderIndex
                    if (newDecoderIndex != null) {
                        decoderIndex = newDecoderIndex
                    }
                    if (url != null && (url != currentUrl || needRecreate)) {
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

        // ---------- 画面队列 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "video-pictq-size", 3L)

        // ---------- 精准 Seek ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "enable-accurate-seek", 1L)

        // ---------- 音频 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "soundtouch", 1L)

        // ---------- 启动即播放 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)

        // ---------- 缓冲（TVBoxOS 同款） ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", (15 * 1024 * 1024).toLong())
        // min-frames=1 减少首帧等待，换台更快
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 1L)
        // 直播低延迟缓存
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max_cached_duration", 300L)

        // ---------- 网络 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", (10 * 1000 * 1000).toLong())
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "http-detect-range-support", 0L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek")
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_clear", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_timeout", -1L)

        // ---------- 探测参数（减小以加速换台） ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", (512 * 1024).toLong())
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", (500 * 1000).toLong())

        // ---------- 协议白名单 ----------
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "protocol_whitelist",
            "file,http,https,tcp,tls,crypto,rtsp,rtp,udp"
        )

        // ============================================================
        // 解码器分支
        // ============================================================
        if (decoderIndex == 0) {
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "skip_loop_filter", 48L)
        } else {
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "threads", 4L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "skip_loop_filter", 0L)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)
        }

        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "avsync-threshold", 100L)

        // ---------- 回调 ----------
        player.setOnPreparedListener {
            player.start()
            methodChannel.invokeMethod("onInfo", mapOf("what" to 3))
        }

        player.setOnErrorListener { _, what, extra ->
            isPlayerError = true
            methodChannel.invokeMethod("onError", mapOf("what" to what, "extra" to extra))
            true
        }

        player.setOnInfoListener { _, what, extra ->
            methodChannel.invokeMethod("onInfo", mapOf("what" to what, "extra" to extra))
            true
        }

        return player
    }

    private fun setUrl(url: String) {
        // 复用现有播放器（reset 比 release+new 快得多）
        val player = ijkMediaPlayer
        if (player != null && !isPlayerError) {
            try {
                player.stop()
                player.reset()
                player.setDisplay(surfaceView.holder)
                player.dataSource = url
                player.prepareAsync()
                return
            } catch (_: Exception) {
                releasePlayer()
            }
        }

        // 新建或出错后重建
        releasePlayer()
        val newPlayer = createPlayer()
        ijkMediaPlayer = newPlayer
        isPlayerError = false

        if (isSurfaceReady) {
            newPlayer.setDisplay(surfaceView.holder)
        }

        try {
            newPlayer.dataSource = url
            newPlayer.prepareAsync()
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
        isPlayerError = false
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        releasePlayer()
    }
}
