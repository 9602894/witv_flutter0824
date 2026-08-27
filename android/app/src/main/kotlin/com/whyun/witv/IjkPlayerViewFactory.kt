package com.whyun.witv

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class IjkPlayerViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<String, Any> ?: emptyMap()
        val url = params["url"] as? String ?: ""
        val decoderIndex = (params["decoderIndex"] as? Int) ?: 0
        return IjkPlayerView(context, url, decoderIndex)
    }
}
