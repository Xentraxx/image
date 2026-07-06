import 'dart:typed_data';

import '../util/input_buffer.dart';
import '../util/output_buffer.dart';
import 'exif_tag.dart';
import 'ifd_container.dart';
import 'ifd_directory.dart';
import 'ifd_value.dart';

/// Tag id of [JPEGInterchangeFormat] (a.k.a. ThumbnailOffset): offset from
/// the TIFF header to the embedded EXIF thumbnail (JPEG) payload, stored in
/// IFD1.
const exifThumbnailOffsetTag = 0x0201;

/// Tag id of [JPEGInterchangeFormatLength] (a.k.a. ThumbnailLength): size in
/// bytes of the embedded EXIF thumbnail payload, stored in IFD1.
const exifThumbnailLengthTag = 0x0202;

/// Stores EXIF data for an Image.
class ExifData extends IfdContainer {
  /// The raw bytes of the embedded EXIF thumbnail (a complete JPEG), if one
  /// was present in IFD1. The thumbnail is referenced out-of-band by the
  /// [exifThumbnailOffsetTag] / [exifThumbnailLengthTag] tags rather than
  /// being stored as a regular IFD value, so it has to be round-tripped
  /// separately from the directory entries.
  ///
  /// When non-empty, [write] appends these bytes after the IFD1 directory and
  /// rewrites the offset/length tags to point at them. When empty, any stale
  /// offset/length tags are dropped so the output never carries dangling
  /// thumbnail pointers (see issue #793).
  Uint8List? thumbnail;

  ExifData() : super();

  ExifData.from(ExifData? other) : super.from(other) {
    thumbnail = other?.thumbnail == null
        ? null
        : Uint8List.fromList(other!.thumbnail!);
  }

  ExifData.fromInputBuffer(InputBuffer input) : super() {
    read(input);
  }

  ExifData clone() => ExifData.from(this);

  bool hasTag(int tag) {
    for (final directory in directories.values) {
      if (directory.containsKey(tag)) {
        return true;
      }
    }
    return false;
  }

  IfdDirectory get imageIfd => this['ifd0'];

  IfdDirectory get thumbnailIfd => this['ifd1'];

  IfdDirectory get exifIfd => this['ifd0'].sub['exif'];

  IfdDirectory get gpsIfd => this['ifd0'].sub['gps'];

  IfdDirectory get interopIfd => this['ifd0'].sub['interop'];

  IfdValue? getTag(int tag) {
    for (final directory in directories.values) {
      if (directory.containsKey(tag)) {
        return directory[tag];
      }
    }
    return null;
  }

  String getTagName(int tag) {
    if (!exifImageTags.containsKey(tag)) {
      return '<unknown>';
    }
    return exifImageTags[tag]!.name;
  }

  @override
  String toString() {
    final s = StringBuffer();
    for (final name in directories.keys) {
      s.write('$name\n');
      final directory = directories[name]!;
      for (final tag in directory.keys) {
        final value = directory[tag];
        if (value == null) {
          s.write('\t${getTagName(tag)}\n');
        } else {
          s.write('\t${getTagName(tag)}: $value\n');
        }
      }
      for (final subName in directory.sub.keys) {
        s.write('$subName\n');
        final subDirectory = directory.sub[subName];
        for (final tag in subDirectory.keys) {
          final value = subDirectory[tag];
          if (value == null) {
            s.write('\t${getTagName(tag)}\n');
          } else {
            s.write('\t${getTagName(tag)}: $value\n');
          }
        }
      }
    }
    return s.toString();
  }

  int getDataSize() => 8 + (directories['ifd0']?.getDataSize() ?? 0);

  void write(OutputBuffer out) {
    final saveEndian = out.bigEndian;

    out
      ..bigEndian = true
      // Tiff header
      ..writeUint16(0x4d4d) // big endian
      ..writeUint16(0x002a)
      ..writeUint32(8); // offset to first ifd block

    if (directories['ifd0'] == null) {
      directories['ifd0'] = IfdDirectory();
    }

    // If a thumbnail payload is present, make sure IFD1 exists so the
    // thumbnail offset/length tags and payload get written out.
    if (thumbnail != null && thumbnail!.isNotEmpty) {
      directories['ifd1'] ??= IfdDirectory();
    }

    // Ensure deterministic ordering: IFD0 must be written first. Use an
    // explicit list of directory names so offsets and next-pointer values
    // are calculated consistently regardless of map insertion order.
    final dirNames = <String>['ifd0'];
    for (final k in directories.keys) {
      if (k != 'ifd0') {
        dirNames.add(k);
      }
    }

    var dataOffset = 8; // offset to first ifd block, from start of tiff header
    final offsets = <String, int>{};
    // Offset (from the TIFF header) where the embedded EXIF thumbnail
    // payload will be written, if any. Computed in the first pass below and
    // consumed in the second pass when writing IFD1.
    var thumbnailOffset = -1;

    for (final name in dirNames) {
      final ifd = directories[name]!;

      // Reconcile the IFD1 thumbnail tags with the actual thumbnail
      // payload. If we have thumbnail bytes, make sure both the offset and
      // length tags are present (their values are finalised below once the
      // thumbnail offset is known). If there is no thumbnail, drop any
      // stale offset/length tags so the output never carries dangling
      // pointers (see issue #793).
      if (name == 'ifd1') {
        if (thumbnail != null && thumbnail!.isNotEmpty) {
          ifd[exifThumbnailOffsetTag] ??= IfdValueLong(0);
          ifd[exifThumbnailLengthTag] ??= IfdValueLong(thumbnail!.length);
          ifd[exifThumbnailLengthTag]!.setInt(thumbnail!.length);
        } else {
          ifd.data.remove(exifThumbnailOffsetTag);
          ifd.data.remove(exifThumbnailLengthTag);
        }
      }

      offsets[name] = dataOffset;

      if (ifd.sub.containsKey('exif')) {
        ifd[0x8769] = IfdValueLong(0);
      } else {
        ifd.data.remove(0x8769);
      }

      if (ifd.sub.containsKey('interop')) {
        ifd[0xA005] = IfdValueLong(0);
      } else {
        ifd.data.remove(0xA005);
      }

      if (ifd.sub.containsKey('gps')) {
        ifd[0x8825] = IfdValueLong(0);
      } else {
        ifd.data.remove(0x8825);
      }

      // ifd block size
      dataOffset += 2 + (12 * ifd.values.length) + 4;

      // storage for large tag values
      for (final value in ifd.values) {
        final dataSize = value.dataSize;
        if (dataSize > 4) {
          dataOffset += dataSize;
        }
      }

      // The thumbnail payload is appended after the IFD1 directory entries,
      // the next-IFD pointer, and any large tag values. Record its offset
      // now so the 0x0201 tag can point at it.
      if (name == 'ifd1' && thumbnail != null && thumbnail!.isNotEmpty) {
        thumbnailOffset = dataOffset;
        dataOffset += thumbnail!.length;
      }

      // storage for sub-ifd blocks
      for (final subName in ifd.sub.keys) {
        final subIfd = ifd.sub[subName];
        offsets[subName] = dataOffset;
        int subSize = 2 + (12 * subIfd.values.length);
        for (final value in subIfd.values) {
          final dataSize = value.dataSize;
          if (dataSize > 4) {
            subSize += dataSize;
          }
        }
        dataOffset += subSize;
      }
    }

    final numIfd = dirNames.length;
    for (int i = 0; i < numIfd; ++i) {
      final name = dirNames[i];
      final ifd = directories[name]!;

      if (ifd.sub.containsKey('exif')) {
        ifd[0x8769]!.setInt(offsets['exif']!);
      }

      if (ifd.sub.containsKey('interop')) {
        ifd[0xA005]!.setInt(offsets['interop']!);
      }

      if (ifd.sub.containsKey('gps')) {
        ifd[0x8825]!.setInt(offsets['gps']!);
      }

      // Point the IFD1 thumbnail offset tag at the payload location
      // computed in the first pass.
      if (name == 'ifd1' && thumbnailOffset >= 0) {
        ifd[exifThumbnailOffsetTag]!.setInt(thumbnailOffset);
      }

      final ifdOffset = offsets[name]!;
      final dataOffset = ifdOffset + 2 + (12 * ifd.values.length) + 4;

      _writeDirectory(out, ifd, dataOffset);

      if (i == numIfd - 1) {
        out.writeUint32(0);
      } else {
        final nextName = dirNames[i + 1];
        out.writeUint32(offsets[nextName]!);
      }

      _writeDirectoryLargeValues(out, ifd);

      // Append the thumbnail payload right after the IFD1 directory and its
      // large tag values, matching the offset recorded above.
      if (name == 'ifd1' && thumbnail != null && thumbnail!.isNotEmpty) {
        out.writeBytes(thumbnail!);
      }

      for (final subName in ifd.sub.keys) {
        final subIfd = ifd.sub[subName];
        final subOffset = offsets[subName]!;
        final dataOffset = subOffset + 2 + (12 * subIfd.values.length);
        _writeDirectory(out, subIfd, dataOffset);
        _writeDirectoryLargeValues(out, subIfd);
      }
    }

    out.bigEndian = saveEndian;
  }

  int _writeDirectory(OutputBuffer out, IfdDirectory ifd, int dataOffset) {
    out.writeUint16(ifd.keys.length);
    final stripOffsetTag = exifTagNameToID['StripOffsets'];
    for (final tag in ifd.keys) {
      final value = ifd[tag]!;

      // Special-case StripOffsets, used by TIFF, that if it points to
      // Undefined value type, then its storing the image data and should
      // be translated to the StripOffsets long type.
      final tagType =
          tag == stripOffsetTag && value.type == IfdValueType.undefined
          ? IfdValueType.long
          : value.type;

      final tagLength =
          tag == stripOffsetTag && value.type == IfdValueType.undefined
          ? 1
          : value.length;

      out
        ..writeUint16(tag)
        ..writeUint16(tagType.index)
        ..writeUint32(tagLength);

      var size = value.dataSize;
      if (size <= 4) {
        value.write(out);
        while (size < 4) {
          out.writeByte(0);
          size++;
        }
      } else {
        out.writeUint32(dataOffset);
        dataOffset += size;
      }
    }
    return dataOffset;
  }

  void _writeDirectoryLargeValues(OutputBuffer out, IfdDirectory ifd) {
    for (final value in ifd.values) {
      final size = value.dataSize;
      if (size > 4) {
        value.write(out);
      }
    }
  }

  bool read(InputBuffer block) {
    final saveEndian = block.bigEndian;
    block.bigEndian = true;

    final blockOffset = block.offset;

    // Tiff header
    final endian = block.readUint16();
    if (endian == 0x4949) {
      // II
      block.bigEndian = false;
      if (block.readUint16() != 0x002a) {
        block.bigEndian = saveEndian;
        return false;
      }
    } else if (endian == 0x4d4d) {
      // MM
      block.bigEndian = true;
      if (block.readUint16() != 0x002a) {
        block.bigEndian = saveEndian;
        return false;
      }
    } else {
      return false;
    }

    int ifdOffset = block.readUint32();

    // IFD blocks
    var index = 0;
    while (ifdOffset > 0) {
      try {
        block.offset = blockOffset + ifdOffset;
        if (block.length < 2) {
          break;
        }

        final directory = IfdDirectory();
        final numEntries = block.readUint16();
        // Each IFD entry is 12 bytes; if the buffer can't hold them all the
        // data is corrupt, so stop rather than reading past the buffer end.
        if (numEntries * 12 > block.length) {
          break;
        }
        final dir = List<_ExifEntry>.generate(
          numEntries,
          (i) => _readEntry(block, blockOffset),
        );

        for (final entry in dir) {
          if (entry.value != null) {
            directory[entry.tag] = entry.value!;
          }
        }
        directories['ifd$index'] = directory;
        index++;

        final nextIfdOffset = block.readUint32();
        if (nextIfdOffset == ifdOffset) {
          break;
        } else {
          ifdOffset = nextIfdOffset;
        }
      } catch (e) {
        // Malformed IFD; stop reading further directories.
        break;
      }
    }

    const subTags = {0x8769: 'exif', 0xA005: 'interop', 0x8825: 'gps'};

    for (final d in directories.values) {
      for (final dt in subTags.keys) {
        if (d.containsKey(dt)) {
          try {
            // ExifOffset
            final ifdOffset = d[dt]!.toInt();
            block.offset = blockOffset + ifdOffset;
            final directory = IfdDirectory();
            final numEntries = block.readUint16();
            final dir = List<_ExifEntry>.generate(
              numEntries,
              (i) => _readEntry(block, blockOffset),
            );

            for (final entry in dir) {
              if (entry.value != null) {
                directory[entry.tag] = entry.value!;
              }
            }
            d.sub[subTags[dt]!] = directory;
          } catch (e) {
            // Malformed sub-IFD (e.g., GPS), skip it
            // Optionally log or collect error info here
            continue;
          }
        }
      }
    }

    // Capture the embedded EXIF thumbnail (IFD1) payload, if any. The
    // thumbnail is referenced out-of-band by the JPEGInterchangeFormat /
    // JPEGInterchangeFormatLength tags (0x0201 / 0x0202), which point at a
    // run of bytes stored after the IFD1 directory entries. Without this
    // the bytes are lost on round-trip and the offset/length tags become
    // dangling pointers (see issue #793).
    final ifd1 = directories['ifd1'];
    if (ifd1 != null) {
      final offsetValue = ifd1[exifThumbnailOffsetTag];
      final lengthValue = ifd1[exifThumbnailLengthTag];
      if (offsetValue != null && lengthValue != null) {
        final thumbOffset = offsetValue.toInt();
        final thumbLength = lengthValue.toInt();
        if (thumbOffset > 0 && thumbLength > 0) {
          final start = blockOffset + thumbOffset;
          if (start + thumbLength <= block.end) {
            block.offset = start;
            thumbnail = Uint8List.fromList(
              block.readBytes(thumbLength).toUint8List(),
            );
          }
        }
      }
    }

    block.bigEndian = saveEndian;
    return false;
  }

  _ExifEntry _readEntry(InputBuffer block, int blockOffset) {
    final tag = block.readUint16();
    final format = block.readUint16();
    final count = block.readUint32();

    final entry = _ExifEntry(tag, null);

    if (format >= IfdValueType.values.length) {
      return entry;
    }

    final f = IfdValueType.values[format];
    final fsize = ifdValueTypeSize[format];
    final size = count * fsize;

    final endOffset = block.offset + 4;

    if (size > 4) {
      final fieldOffset = block.readUint32();
      block.offset = fieldOffset + blockOffset;
    }

    if (block.offset + size > block.end) {
      return entry;
    }

    final data = block.readBytes(size);

    switch (f) {
      case IfdValueType.none:
        break;
      case IfdValueType.sByte:
        entry.value = IfdValueSByte.data(data, count);
        break;
      case IfdValueType.byte:
        entry.value = IfdByteValue.data(data, count);
        break;
      case IfdValueType.undefined:
        entry.value = IfdValueUndefined.data(data, count);
        break;
      case IfdValueType.ascii:
        entry.value = IfdValueAscii.data(data, count);
        break;
      case IfdValueType.short:
        entry.value = IfdValueShort.data(data, count);
        break;
      case IfdValueType.long:
        entry.value = IfdValueLong.data(data, count);
        break;
      case IfdValueType.rational:
        entry.value = IfdValueRational.data(data, count);
        break;
      case IfdValueType.sRational:
        entry.value = IfdValueSRational.data(data, count);
        break;
      case IfdValueType.sShort:
        entry.value = IfdValueSShort.data(data, count);
        break;
      case IfdValueType.sLong:
        entry.value = IfdValueSLong.data(data, count);
        break;
      case IfdValueType.single:
        entry.value = IfdValueSingle.data(data, count);
        break;
      case IfdValueType.double:
        entry.value = IfdValueDouble.data(data, count);
        break;
      case IfdValueType.ifd:
        if (count == 1) {
          entry.value = IfdValueIfd.data(data);
        }
        break;
    }

    block.offset = endOffset;

    return entry;
  }
}

class _ExifEntry {
  int tag;
  IfdValue? value;
  _ExifEntry(this.tag, this.value);
}
