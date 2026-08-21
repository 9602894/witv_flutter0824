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
    private var decoderIndex: Int = 0  // 0=硬解(画质优先), 1=软解(兼容优先)

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

        // ============================================================
        // 画质优化核心配置（参考 TVBoxOS 硬解方案 + ijkplayer 最佳实践）
        // ============================================================

        // ---------- 渲染输出格式：OpenGL ES2，画质最佳 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "overlay-format", IjkMediaPlayer.SDL_FCC__ES2)

        // ---------- 画面队列，提升渲染平滑度 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "video-pictq-size", 3)

        // ---------- 精准 Seek，减少画面模糊/花屏 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "enable-accurate-seek", 1)

        // ---------- 音频优化 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "soundtouch", 1)

        // ---------- 启动即播放 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1)

        // ---------- 缓冲策略（TVBoxOS 同款 15MB） ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", 15 * 1024 * 1024)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 3)

        // ---------- 网络与重连 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", 10 * 1000 * 1000)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "http-detect-range-support", 0)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek")

        // ---------- 探测参数 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024 * 1024)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 2 * 1000 * 1000)

        // ---------- 协议白名单 ----------
        player.setOption(
            IjkMediaPlayer.OPT_CATEGORY_FORMAT,
            "protocol_whitelist",
            "file,http,https,tcp,tls,crypto,rtsp,rtp,udp"
        )

        // ============================================================
        // 解码器分支：硬解 vs 软解
        // ============================================================
        if (decoderIndex == 0) {
            // ==================== 硬解模式（默认，画质最好） ====================
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 1)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 1)
            // 硬解时 framedrop 小一点保画质
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1)
            // 硬解时 skip_loop_filter 由硬件内部处理，不影响画质
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "skip_loop_filter", 48)
        } else {
            // ==================== 软解模式（兼容性最好） ====================
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 0)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 0)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 0)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 0)
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-handle-resolution-change", 0)
            // 软解多线程
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "threads", 4)
            // 软解时保画质：不跳过环路滤波（0=不跳过，画质最好）
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_CODEC, "skip_loop_filter", 0)
            // 软解时解码跟不上才丢帧
            player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5)
        }

        // ---------- 同步阈值 ----------
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "avsync-threshold", 100)

        // ---------- 回调 ----------
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
            it.stop()
            it.setDisplay(null)
            it.release()
        }
        ijkMediaPlayer = null
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        releasePlayer()
    }
}
