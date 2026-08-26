import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
// 移除 media_kit 导入
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogService.init();

  // 确保焦点系统正确初始化（TV/遥控器支持）
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;

  // 强制横屏
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // 捕获错误
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    LogService.writeCrashLog(details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    LogService.writeCrashLog(error, stack);
    return true;
  };

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SettingsService(),
      child: MaterialApp(
        title: 'Witv',
        theme: ThemeData.dark(),
        home: HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

