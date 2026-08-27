package com.whyun.witv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 注意：IjkPlayerViewFactory 的构造函数无参数，不要传入任何东西
        flutterEngine.platformViewsController.registry.registerViewFactory("IjkPlayer", IjkPlayerViewFactory())
    }
}
