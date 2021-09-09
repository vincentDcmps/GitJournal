/*
Copyright 2020-2021 Vishesh Handa <me@vhanda.in>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

import 'package:gitjournal/core/notes_folder_fs.dart';
import 'package:gitjournal/error_reporting.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:gitjournal/utils/datetime.dart';
import 'md_yaml_doc.dart';
import 'md_yaml_doc_codec.dart';
import 'note_serializer.dart';

typedef void NoteSelectedFunction(Note note);
typedef bool NoteBoolPropertyFunction(Note note);

/// Move this to NotesFolderFS
enum NoteLoadState {
  None,
  Loading,
  Loaded,
  NotExists,
  Error,
}

enum NoteType { Unknown, Checklist, Journal, Org }

class NoteFileFormatInfo {
  static List<String> allowedExtensions = ['.md', '.org', '.txt'];

  static String defaultExtension(NoteFileFormat format) {
    switch (format) {
      case NoteFileFormat.Markdown:
        return ".md";
      case NoteFileFormat.OrgMode:
        return '.org';
      case NoteFileFormat.Txt:
        return ".txt";
      default:
        return ".md";
    }
  }

  static bool isAllowedFileName(String filePath) {
    var noteFilePath = filePath.toLowerCase();
    for (var ext in allowedExtensions) {
      if (noteFilePath.endsWith(ext)) {
        return true;
      }
    }

    return false;
  }
}

// FIXME: Treat Markdown and Markdown + YAML differently
enum NoteFileFormat {
  Markdown,
  OrgMode,
  Txt,
}

class Note {
  NotesFolderFS parent;
  String? _filePath;

  String _title = "";
  DateTime? _created;
  DateTime? _modified;
  String _body = "";
  NoteType _type = NoteType.Unknown;
  Set<String> _tags = {};
  Map<String, dynamic> _extraProps = {};

  NoteFileFormat? _fileFormat;

  MdYamlDoc _data = MdYamlDoc();
  late NoteSerializer noteSerializer;

  DateTime fileLastModified;

  var _loadState = NoteLoadState.None;
  var _serializer = MarkdownYAMLCodec();

  Note(this.parent, this._filePath, this.fileLastModified) {
    var settings = NoteSerializationSettings.fromConfig(parent.config);
    noteSerializer = NoteSerializer.fromConfig(settings);
  }

  Note.newNote(
    this.parent, {
    Map<String, dynamic> extraProps = const {},
    String fileName = "",
  }) : fileLastModified = DateTime.fromMillisecondsSinceEpoch(0) {
    created = DateTime.now();
    _loadState = NoteLoadState.Loaded;
    _fileFormat = NoteFileFormat.Markdown;
    var settings = NoteSerializationSettings.fromConfig(parent.config);
    noteSerializer = NoteSerializer.fromConfig(settings);

    if (extraProps.isNotEmpty) {
      extraProps.forEach((key, value) {
        _data.props[key] = value;
      });
      noteSerializer.decode(_data, this);
    }

    if (fileName.isNotEmpty) {
      // FIXME: We should ensure a note with this fileName does not already
      //        exist
      if (!NoteFileFormatInfo.isAllowedFileName(fileName)) {
        fileName +=
            NoteFileFormatInfo.defaultExtension(NoteFileFormat.Markdown);
      }
      _filePath = p.join(parent.folderPath, fileName);
      Log.i("Constructing new note with path $_filePath");
    }
  }

  String get filePath {
    if (_filePath == null) {
      var fp = "";
      try {
        fp = p.join(parent.folderPath, _buildFileName());
      } catch (e, stackTrace) {
        Log.e("_buildFileName: $e");
        logExceptionWarning(e, stackTrace);
        fp = p.join(parent.folderPath, const Uuid().v4());
      }
      switch (_fileFormat) {
        case NoteFileFormat.OrgMode:
          if (!fp.toLowerCase().endsWith('.org')) {
            fp += '.org';
          }
          break;

        case NoteFileFormat.Txt:
          if (!fp.toLowerCase().endsWith('.txt')) {
            fp += '.txt';
          }
          break;

        case NoteFileFormat.Markdown:
        default:
          if (!fp.toLowerCase().endsWith('.md')) {
            fp += '.md';
          }
          break;
      }

      _filePath = fp;
    }

    return _filePath as String;
  }

  set filePath(String newpath) {
    _filePath = newpath;
    _notifyModified();
  }

  String get fileName {
    return p.basename(filePath);
  }

  DateTime? get created {
    return _created;
  }

  set created(DateTime? dt) {
    if (!canHaveMetadata) return;

    _created = dt;
    _notifyModified();
  }

  DateTime? get modified {
    return _modified;
  }

  set modified(DateTime? dt) {
    if (!canHaveMetadata) return;

    _modified = dt;
    _notifyModified();
  }

  void updateModified() {
    modified = DateTime.now();
  }

  String get body {
    return _body;
  }

  set body(String newBody) {
    if (newBody == _body) {
      return;
    }

    _body = newBody;

    _notifyModified();
  }

  String get title {
    return _title;
  }

  set title(String title) {
    if (title != _title) {
      _title = title;
      _notifyModified();
    }
  }

  NoteType get type {
    return _type;
  }

  set type(NoteType type) {
    if (!canHaveMetadata) return;

    if (type != _type) {
      _type = type;
      _notifyModified();
    }
  }

  Set<String> get tags {
    return _tags;
  }

  set tags(Set<String> tags) {
    if (!canHaveMetadata) return;

    _tags = tags;
    _notifyModified();
  }

  Map<String, dynamic> get extraProps {
    return _extraProps;
  }

  set extraProps(Map<String, dynamic> props) {
    if (!canHaveMetadata) return;

    _extraProps = props;
    _notifyModified();
  }

  bool get canHaveMetadata {
    if (_fileFormat == NoteFileFormat.Txt ||
        _fileFormat == NoteFileFormat.OrgMode) {
      return false;
    }
    return parent.config.yamlHeaderEnabled;
  }

  MdYamlDoc get data {
    noteSerializer.encode(this, _data);
    return _data;
  }

  set data(MdYamlDoc data) {
    _data = data;
    noteSerializer.decode(_data, this);

    _notifyModified();
  }

  NoteLoadState get loadState {
    return _loadState;
  }

  set loadState(NoteLoadState state) {
    _loadState = state;
    _notifyModified();
  }

  String serialize() {
    var contents = _serializer.encode(data);
    // Make sure all docs end with a \n
    if (!contents.endsWith('\n')) {
      contents += '\n';
    }

    return contents;
  }

  @override
  int get hashCode => _filePath.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Note &&
          runtimeType == other.runtimeType &&
          _filePath == other._filePath &&
          _data == other._data;

  @override
  String toString() {
    return 'Note{filePath: $_filePath, created: $created, modified: $modified, data: $_data, loadState: $_loadState}';
  }

  void _notifyModified() {
    parent.noteModified(this);
  }

  String pathSpec() {
    return p.join(parent.pathSpec(), fileName);
  }

  String _buildFileName() {
    var date = created ?? modified ?? fileLastModified;
    var isJournal = type == NoteType.Journal;
    switch (!isJournal
        ? parent.config.fileNameFormat
        : parent.config.journalFileNameFormat) {
      case NoteFileNameFormat.SimpleDate:
        return toSimpleDateTime(date);
      case NoteFileNameFormat.DateOnly:
        var dateStr = toDateString(date);
        return ensureFileNameUnique(parent.folderPath, dateStr, ".md");
      case NoteFileNameFormat.FromTitle:
        if (title.isNotEmpty) {
          return buildTitleFileName(parent.folderPath, title);
        } else {
          return toSimpleDateTime(date);
        }
      case NoteFileNameFormat.Iso8601:
        return toIso8601(date);
      case NoteFileNameFormat.Iso8601WithTimeZone:
        return toIso8601WithTimezone(date);
      case NoteFileNameFormat.Iso8601WithTimeZoneWithoutColon:
        return toIso8601WithTimezone(date).replaceAll(":", "_");
      case NoteFileNameFormat.UuidV4:
        return const Uuid().v4();
      case NoteFileNameFormat.Zettelkasten:
        return toZettleDateTime(date);
    }

    return date.toString();
  }

  NoteFileFormat? get fileFormat {
    return _fileFormat;
  }

  set fileFormat(NoteFileFormat? format) {
    _fileFormat = format;
    _notifyModified();
  }
}

String ensureFileNameUnique(String parentDir, String name, String ext) {
  var fileName = name + ext;
  var fullPath = p.join(parentDir, fileName);
  var file = File(fullPath);
  if (!file.existsSync()) {
    return fileName;
  }

  for (var i = 1;; i++) {
    var fileName = name + "_$i$ext";
    var fullPath = p.join(parentDir, fileName);
    var file = File(fullPath);
    if (!file.existsSync()) {
      return fileName;
    }
  }
}

String buildTitleFileName(String parentDir, String title) {
  // Sanitize the title - these characters are not allowed in Windows
  title = title.replaceAll(RegExp(r'[/<\>":|?*]'), '_');

  return ensureFileNameUnique(parentDir, title, ".md");
}
