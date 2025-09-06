import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:ui'; // ← 追加
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:in_app_review/in_app_review.dart';
import 'review_request.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReviewRequest.onAppLaunch(); // ★これを追加
  runApp(MemoApp());
}

class Memo {
  String text;
  List<Memo> children;
  int? colorValue; // null=デフォルト色
  String? imagePath; // 画像ファイルのパスを追加

  Memo({required this.text, this.colorValue, this.imagePath, List<Memo>? children})
    : children = children ?? [];

  Map<String, dynamic> toJson() => {
    'text': text,
    'colorValue': colorValue, // nullも保存
    'imagePath': imagePath,
    'children': children.map((c) => c.toJson()).toList(),
  };

  factory Memo.fromJson(Map<String, dynamic> json) => Memo(
    text: json['text'],
    colorValue: json['colorValue'], // int?型でOK
    imagePath: json['imagePath'],
    children:
        (json['children'] as List<dynamic>?)
            ?.map((c) => Memo.fromJson(c))
            .toList() ??
        [],
  );
}

class MemoApp extends StatelessWidget {
  const MemoApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // MaterialAppはここではダーク・ライトを決められないので、homeで判定
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const MemoListPage(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''), // 英語
        Locale('ja', ''), // 日本語
      ],
    );
  }
}

class MemoListPage extends StatefulWidget {
  final List<Memo>? parentList;
  final String? parentKey;
  final String? title;
  final VoidCallback? onChanged; // ←追加

  const MemoListPage({Key? key, this.parentList, this.parentKey, this.title, this.onChanged})
    : super(key: key);

  @override
  State<MemoListPage> createState() => _MemoListPageState();
}

class _MemoListPageState extends State<MemoListPage> {
  late List<Memo> memos; // ←lateで初期化
  List<List<Memo>> undoStack = []; // ← Undo用
  final String saveKey = "memo_list";

  // ロケールと言語を取得
  late Locale _locale;
  late bool isJapanese;

  // テーマ
  late bool isDarkMode;

  // サブメモが実質的にあるかを判定（空テキストだけの子は除外）
  bool hasVisibleChildren(Memo memo) {
    return memo.children.any(
      (child) => child.text.trim().isNotEmpty || hasVisibleChildren(child),
    );
  }

  Color? _getMemoTextColor(Memo memo, bool isDarkMode) {
    if (memo.colorValue == null) {
      // デフォルト色（CardThemeに任せる、明示指定しないのでnullを返す）
      return null;
    } else {
      final bgColor = Color(memo.colorValue!);
      // 明度に応じて文字色を決定（ダーク/ライト問わず背景が淡色なら黒文字、それ以外は白文字）
      return bgColor.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    }
  }

  Color getContrastTextColor(Color bgColor) {
    // 明るい色の上は黒文字、暗い色の上は白文字
    return bgColor.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  }

  bool _isDeleteLocked = true;

  // 画面初期化
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 言語判定
    _locale = Localizations.localeOf(context);
    isJapanese = _locale.languageCode == 'ja';
    // ダークモード判定
    isDarkMode = MediaQuery.of(context).platformBrightness == Brightness.dark;
  }

  @override
  void initState() {
    super.initState();
    memos = [];
    // 1フレーム遅らせてからロード
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.parentList == null) {
        _loadMemos();
      } else {
        // 親リストの参照をそのまま使う
        setState(() {
          memos = widget.parentList!;
        });
      }
    });
  }

  Future<void> _addImageMemo() async {
    final picker = ImagePicker();

    // ダイアログで選択肢を出す
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(isJapanese ? "画像の追加方法を選択" : "Select image source"),
        children: [
          SimpleDialogOption(
            child: Text(isJapanese ? "カメラで撮影" : "Camera"),
            onPressed: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          SimpleDialogOption(
            child: Text(isJapanese ? "ギャラリーから選択" : "Gallery"),
            onPressed: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ],
      ),
    );
    if (source == null) return;

    // 画像取得
    final picked = await picker.pickImage(source: source, imageQuality: 80);
    if (picked == null) return;

    // 永続保存用にアプリディレクトリにコピー
    final appDir = await getApplicationDocumentsDirectory();
    final fileName = DateTime.now().millisecondsSinceEpoch.toString() + ".png";
    final savedPath = "${appDir.path}/$fileName";
    final savedFile = await File(picked.path).copy(savedPath);

    // タイトル入力
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isJapanese ? "画像のタイトルを入力" : "Enter image title"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: isJapanese ? 'タイトル' : 'Title',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(isJapanese ? "追加" : "Add"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isJapanese ? "キャンセル" : "Cancel"),
          ),
        ],
      ),
    );

    if (ok != true || controller.text.trim().isEmpty) {
      // キャンセル時はファイルを削除
      await savedFile.delete();
      return;
    }

    // Undoスタック追加
    undoStack.add(List.from(memos.map((m) => Memo.fromJson(m.toJson()))));
    setState(() {
      memos.add(Memo(
        text: controller.text.trim(),
        imagePath: savedFile.path,
      ));
    });
    if (widget.onChanged != null) widget.onChanged!();
  }

  Future<void> _loadMemos() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(saveKey);
    if (data != null) {
      final jsonList = json.decode(data) as List<dynamic>;
      setState(() {
        memos = jsonList.map((e) => Memo.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveMemos() async {
    // ルート（parentList==null）の場合のみセーブ
    if (widget.parentList == null) {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = memos.map((e) => e.toJson()).toList();
      prefs.setString(saveKey, json.encode(jsonList));
    }
  }

  void _addMemo() {
    TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(isJapanese ? 'メモを追加' : 'Add Memo'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: isJapanese ? 'メモ内容を入力' : 'Enter memo content',
            ),
            onSubmitted: (_) => _submitMemo(controller),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _submitMemo(controller);
              },
              child: Text(isJapanese ? '追加' : 'Add'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text(isJapanese ? 'キャンセル' : 'Cancel'),
            ),
          ],
        );
      },
    );
  }

  // Memo追加時の色指定はnull
  void _submitMemo(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isNotEmpty) {
      // Undoスタックにpush
      undoStack.add(List.from(memos.map((m) => Memo.fromJson(m.toJson()))));
      setState(() {
        memos.add(Memo(text: text)); // colorValue: null
      });
      if (widget.onChanged != null) widget.onChanged!();
      Navigator.pop(context);
    }
  }

  void _editMemo(int index) {
    TextEditingController controller = TextEditingController(
      text: memos[index].text,
    );
    showDialog(
      context: context,
      builder: (_) {
        final locale = Localizations.localeOf(context);
        final isJapanese = locale.languageCode == 'ja';
        return AlertDialog(
          title: Text(isJapanese ? 'メモを編集' : 'Edit Memo'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: isJapanese ? '新しいメモ内容を入力' : 'Edit memo content',
            ),
            onSubmitted: (_) => _submitEditMemo(index, controller),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _submitEditMemo(index, controller);
              },
              child: Text(isJapanese ? '保存' : 'Save'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text(isJapanese ? 'キャンセル' : 'Cancel'),
            ),
          ],
        );
      },
    );
  }

  void _submitEditMemo(int index, TextEditingController controller) {
    final newText = controller.text.trim();
    if (newText.isNotEmpty && newText != memos[index].text) {
      undoStack.add(List.from(memos.map((m) => Memo.fromJson(m.toJson()))));
      setState(() {
        memos[index].text = newText;
      });
      if (widget.onChanged != null) widget.onChanged!();
    }
    Navigator.pop(context);
  }

  void _deleteMemo(int index) {
    // Undoスタックにpush
    undoStack.add(List.from(memos.map((m) => Memo.fromJson(m.toJson()))));
    setState(() {
      memos.removeAt(index);
    });
    if (widget.onChanged != null) widget.onChanged!();
  }

  void _undo() {
    if (undoStack.isNotEmpty) {
      setState(() {
        memos = undoStack.removeLast();
      });
      if (widget.onChanged != null) widget.onChanged!();
    }
  }

  void _openChildMemo(int index) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoListPage(
          parentList: memos[index].children, // 参照をそのまま渡す！
          title: memos[index].text, // ←ここに親のメモのテキストを渡す！
          onChanged: widget.onChanged ?? _saveMemos, // ←親のonChangedを渡す
        ),
      ),
    );
    // 戻ってきたときに保存
    _saveMemos(); // 念のため自分でも保存
    setState(() {});
  }

  // 並び替え
  void _onReorder(int oldIndex, int newIndex) {
    undoStack.add(List.from(memos.map((m) => Memo.fromJson(m.toJson()))));
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final Memo moved = memos.removeAt(oldIndex);
      memos.insert(newIndex, moved);
    });
    if (widget.onChanged != null) widget.onChanged!();
  }

  // --- カラー変更ダイアログ ---
  void _changeMemoColor(int index) async {
    Color? picked = await showDialog<Color>(
      context: context,
      builder: (_) {
        final cardColor = Theme.of(context).cardColor;
        final List<Color?> palette = [
        null, // デフォルト色（下で上書き）
        Colors.yellow[100]!,      // 付箋らしい淡い黄色
        Colors.pink[100]!,        // 淡いピンク
        Colors.blue[100]!,        // 淡い青
        Colors.green[100]!,       // 淡いグリーン
        Colors.orange[100]!,      // 淡いオレンジ
        Colors.purple[100]!,      // 淡いパープル
        Colors.grey[200]!,        // 淡いグレー
        Colors.white,             // 白も入れておくとGood
        ];
        return AlertDialog(
          title: Text(isJapanese ? 'メモの色を選択' : 'Select memo color'),
          content: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              children: palette
                  .map((color) => _buildColorCircle(index, color, cardColor))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                memos[index].colorValue == null
                    ? null
                    : Color(memos[index].colorValue!),
              ),
              child: Text(isJapanese ? 'キャンセル' : 'Cancel'),
            ),
          ],
        );
      },
    );

    // nullはデフォルト色に戻す
    if (picked != null || (picked == null && memos[index].colorValue != null)) {
      setState(() {
        memos[index].colorValue = picked?.value;
      });
      if (widget.onChanged != null) widget.onChanged!();
    }
  }

  // 色サークル生成（nullはデフォルト色用）
  Widget _buildColorCircle(int index, Color? color, Color defaultColor) {
    return InkWell(
      onTap: () => Navigator.pop(context, color),
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color ?? defaultColor,
          border: Border.all(
            width: color == null ? 3 : 2,
            color: color == null ? Colors.deepPurple : Colors.black12,
          ),
        ),
        child: color == null
            ? Icon(Icons.refresh, size: 18, color: Colors.black54)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ここで毎回判定することで、どんな状況でもロケールに合ったタイトルになる
    final locale = Localizations.localeOf(context);
    final isJapanese = locale.languageCode == 'ja';
    final String appBarTitle =
        widget.title ?? (isJapanese ? 'メモ帳' : 'memo pad');

    // 端末ダークモード判定も都度取得（変更検知のため）
    final isDarkMode =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final theme = isDarkMode ? ThemeData.dark() : ThemeData.light();

    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: Text(appBarTitle),
          actions: [
            IconButton(
              icon: Icon(Icons.lock, color: _isDeleteLocked ? Colors.red : Colors.grey),
              tooltip: isJapanese
                  ? (_isDeleteLocked ? "ゴミ箱ロック中（タップで解除）" : "ゴミ箱アンロック中（タップでロック）")
                  : (_isDeleteLocked ? "Trash locked (tap to unlock)" : "Trash unlocked (tap to lock)"),
              onPressed: () {
                setState(() {
                  _isDeleteLocked = !_isDeleteLocked;
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: isJapanese ? "元に戻す" : "Undo",
              onPressed: undoStack.isNotEmpty ? _undo : null,
            ),
          ],
        ),
        body:memos.isEmpty
            ? Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sticky_note_2, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                isJapanese
                    ? '右下の「＋」ボタンでメモを作成できます'
                    : 'Tap the "+" button at the bottom right to create a memo.',
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        )
        : ReorderableListView.builder(
          itemCount: memos.length,
          onReorder: _onReorder,
          itemBuilder: (context, index) {
            final Color bgColor = memos[index].colorValue != null
                ? Color(memos[index].colorValue!)
                : Theme.of(context).cardColor;
            final Color iconColor = getContrastTextColor(bgColor);
            final Color textColor = getContrastTextColor(bgColor);
            return Card(
              key: ValueKey(memos[index]), // これ重要
              color: memos[index].colorValue != null
                  ? Color(memos[index].colorValue!)
                  : null, // nullならデフォルトCard色
              child: ListTile(
                title: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _editMemo(index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: Text(
                      memos[index].text,
                      style: TextStyle(
                        color: textColor,
                      ),
                    ),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ★画像アイコン（画像付きメモのみ表示）
                    if (memos[index].imagePath != null)
                      IconButton(
                        icon: Icon(Icons.image, color: iconColor),
                        tooltip: isJapanese ? "画像を表示" : "Show image",
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (_) => Dialog(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: SizedBox(
                                      width: 300, // 適宜調整
                                      height: 300, // 適宜調整
                                      child: InteractiveViewer(
                                        minScale: 0.5,
                                        maxScale: 4.0,
                                        child: Image.file(File(memos[index].imagePath!)),
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    child: Text(isJapanese ? "閉じる" : "Close"),
                                    onPressed: () => Navigator.pop(context),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    // カラー変更ボタン
                    IconButton(
                      icon: Icon(Icons.color_lens, color: iconColor),
                      tooltip: isJapanese ? "色を変更" : "Change color",
                      onPressed: () => _changeMemoColor(index),
                    ),
                    // →ボタン＋サブメモ数バッジ
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        IconButton(
                          icon: Icon(Icons.arrow_forward, color: iconColor),
                          tooltip: isJapanese ? "下位メモへ" : "Sub-memo",
                          onPressed: () => _openChildMemo(index),
                        ),
                        // サブメモ数が1以上の時だけバッジを表示
                        if (hasVisibleChildren(memos[index]))
                          Positioned(
                            right: 6,
                            top: 6,
                            child: IgnorePointer( // ←これを追加！
                              child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.blueAccent.withOpacity(0.8),
                                // 優しい青
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              child: Center(
                                child: Text(
                                  '${memos[index].children.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          ),
                      ],
                    ),
                    IconButton(
                      icon: Icon(
                        _isDeleteLocked ? Icons.delete_forever : Icons.delete,
                        color: _isDeleteLocked ? Colors.grey : iconColor,
                      ),
                      tooltip: isJapanese
                          ? (_isDeleteLocked ? "ロック中（解除して削除可能）" : "削除")
                          : (_isDeleteLocked ? "Locked (unlock to delete)" : "Delete"),
                      onPressed: _isDeleteLocked ? null : () => _deleteMemo(index),
                    ),                  ],
                ),
              ),
            );
          },
        ),
        floatingActionButton: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FloatingActionButton(
              heroTag: "imgMemo",
              onPressed: _addImageMemo, // ←追加
              child: Icon(Icons.camera_alt),
              tooltip: isJapanese ? "画像付きメモ" : "Image Memo",
            ),
            SizedBox(width: 16),
            FloatingActionButton(
              heroTag: "addMemo",
              onPressed: _addMemo,
              child: Icon(Icons.add),
              tooltip: isJapanese ? 'メモ追加' : 'Add memo',
            ),
          ],
        ),
      ),
    );
  }
}
