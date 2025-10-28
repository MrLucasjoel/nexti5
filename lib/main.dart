import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

const String BASE_URL = "https://sua-api.exemplo"; // <- ajuste
const String UPLOAD_PATH = "/upload"; // <- ajuste conforme sua API
const String API_TOKEN = "COLOQUE_SEU_TOKEN_AQUI"; // ou gerencie via login seguro

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // carrega câmeras
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nexti5',
      theme: ThemeData.dark(),
      home: RecorderHome(cameras: cameras),
    );
  }
}

class RecorderHome extends StatefulWidget {
  final List<CameraDescription> cameras;
  const RecorderHome({Key? key, required this.cameras}) : super(key: key);

  @override
  State<RecorderHome> createState() => _RecorderHomeState();
}

class _RecorderHomeState extends State<RecorderHome> {
  CameraController? _controller;
  bool _isRecording = false;
  String _status = "Pronto";
  XFile? lastVideo;
  Timer? _autoStopTimer;

  @override
  void initState() {
    super.initState();
    _initPermissionsAndCamera();
  }

  Future<void> _initPermissionsAndCamera() async {
    final camStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    final storageStatus = await Permission.storage.request();

    if (!camStatus.isGranted || !micStatus.isGranted) {
      setState(() => _status = "Permissões negadas. Conceda câmera e microfone.");
      return;
    }

    if (widget.cameras.isEmpty) {
      setState(() => _status = "Nenhuma câmera disponível.");
      return;
    }

    final cam = widget.cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    _controller = CameraController(cam, ResolutionPreset.high, enableAudio: true);
    try {
      await _controller!.initialize();
      setState(() => _status = "Câmera pronta");
    } catch (e) {
      setState(() => _status = "Erro ao iniciar câmera: $e");
    }
  }

  @override
  void dispose() {
    _autoStopTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _recordTimedClip({int seconds = 8}) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isRecording) return;

    final dir = await getTemporaryDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final filePath = "${dir.path}/gol_$timestamp.mp4";

    try {
      await _controller!.startVideoRecording();
      setState(() {
        _isRecording = true;
        _status = "Gravando... ($seconds s)";
      });

      // auto stop
      _autoStopTimer = Timer(Duration(seconds: seconds), () async {
        await _stopRecordingAndUpload(filePath);
      });
    } catch (e) {
      setState(() => _status = "Erro ao iniciar gravação: $e");
    }
  }

  Future<void> _stopRecordingAndUpload(String targetPath) async {
    if (_controller == null || !_controller!.value.isRecordingVideo) return;

    try {
      final XFile rawVideo = await _controller!.stopVideoRecording();
      _autoStopTimer?.cancel();
      setState(() {
        _isRecording = false;
        _status = "Gravação salva temporariamente";
      });

      // Mova o arquivo para targetPath (porque XFile.path pode apontar para temp)
      final savedFile = await _moveFile(rawVideo.path, targetPath);
      lastVideo = XFile(savedFile.path);
      setState(() => _status = "Vídeo pronto: ${savedFile.path}");

      // envia para a API
      await _uploadVideoFile(savedFile, extraFields: {
        'match_id': 'PARTIDA123', // ajuste: enviar ID da partida real
        'team': 'time_a',         // ajuste: time que marcou
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      setState(() => _status = "Erro ao parar/gravar: $e");
      _isRecording = false;
    }
  }

  Future<File> _moveFile(String fromPath, String toPath) async {
    final file = File(fromPath);
    final newFile = await file.copy(toPath);
    return newFile;
  }

  Future<void> _uploadVideoFile(File file, {Map<String, String>? extraFields}) async {
    setState(() => _status = "Enviando vídeo...");
    final uri = Uri.parse(BASE_URL + UPLOAD_PATH);
    final request = http.MultipartRequest('POST', uri);

    // Se sua API usa token bearer
    request.headers['Authorization'] = 'Bearer $API_TOKEN';

    // campos extras
    extraFields?.forEach((k, v) => request.fields[k] = v);

    final stream = http.ByteStream(file.openRead());
    final length = await file.length();
    final multipartFile = http.MultipartFile('file', stream, length, filename: file.path.split('/').last);

    request.files.add(multipartFile);

    try {
      final response = await request.send().timeout(Duration(seconds: 60));
      final respStr = await response.stream.bytesToString();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() => _status = "Upload concluído");
      } else {
        setState(() => _status = "Falha no upload: ${response.statusCode} - $respStr");
      }
    } catch (e) {
      setState(() => _status = "Erro upload: $e");
    }
  }

  // UI helpers
  Widget _buildCameraPreview() {
    if (_controller == null) {
      return Center(child: Text("Inicializando câmera...", style: TextStyle(color: Colors.white)));
    }
    if (!_controller!.value.isInitialized) {
      return Center(child: Text("Câmera não inicializada", style: TextStyle(color: Colors.white)));
    }
    return CameraPreview(_controller!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Gols Recorder'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(child: Container(color: Colors.black, child: _buildCameraPreview())),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12),
            child: Column(
              children: [
                Text(_status, style: TextStyle(color: Colors.white)),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      icon: Icon(Icons.fiber_manual_record),
                      label: Text(_isRecording ? 'Gravando' : 'Start manual'),
                      onPressed: () async {
                        if (!_isRecording) {
                          // grava manualmente até pressionar stop
                          final dir = await getTemporaryDirectory();
                          final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
                          final filePath = "${dir.path}/manual_$timestamp.mp4";
                          try {
                            await _controller!.startVideoRecording();
                            setState(() {
                              _isRecording = true;
                              _status = "Gravando manual...";
                            });
                          } catch (e) {
                            setState(() => _status = "Erro iniciar gravação manual: $e");
                          }
                        }
                      },
                    ),
                    ElevatedButton.icon(
                      icon: Icon(Icons.stop),
                      label: Text('Stop'),
                      onPressed: () async {
                        if (_isRecording) {
                          final dir = await getTemporaryDirectory();
                          final filePath = "${dir.path}/manual_stop_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.mp4";
                          await _stopRecordingAndUpload(filePath);
                        }
                      },
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      child: Text('GOL', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      onPressed: () => _recordTimedClip(seconds: 8), // grava 8s
                    ),
                  ],
                ),
                SizedBox(height: 8),
                if (lastVideo != null)
                  Text('Último clipe: ${lastVideo!.path.split('/').last}', style: TextStyle(color: Colors.white70)),
                SizedBox(height: 8),
                Text('Dica: toque GOL quando ocorrer o gol — o app grava 8s e envia automaticamente.',
                    style: TextStyle(fontSize: 12, color: Colors.white70), textAlign: TextAlign.center),
              ],
            ),
          )
        ],
      ),
    );
  }
}
