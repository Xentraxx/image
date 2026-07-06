import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart';
import 'package:image/src/formats/jpeg/jpeg_marker.dart';
import 'package:image/src/util/input_buffer.dart';
import 'package:test/test.dart';

/// Tests for issue #793: `injectJpgExif` used to drop the JFIF (APP0) segment
/// and destroy the EXIF thumbnail, leaving dangling IFD1 offset tags.
///
/// These tests guard against regressions of both fixes:
///   * the JFIF APP0 segment (and any other segment preceding the EXIF APP1)
///     is preserved verbatim, and
///   * the embedded EXIF thumbnail payload is round-tripped, with the
///     JPEGInterchangeFormat / JPEGInterchangeFormatLength tags (0x0201 /
///     0x0202) pointing at valid bytes (or being dropped when no thumbnail
///     is available, so the output never carries dangling pointers).
///
/// The tests use the public [decodeJpgExif] / [injectJpgExif] wrappers, the
/// same API the issue reproduces with.

void main() {
  /// JPEGs in the test corpus that have a JFIF APP0 segment immediately
  /// followed by an EXIF APP1 block that itself contains an embedded
  /// thumbnail (IFD1). These are exactly the files that used to be
  /// corrupted by `injectJpgExif`.
  const jfifAndExifThumbnailFiles = <String>[
    'test/_data/jpg/icc_profile_data.jpg',
    'test/_data/jpg/icc_profile_Lower_Left.jpg',
    'test/_data/jpg/icc_profile_Lower_Right.jpg',
    'test/_data/jpg/icc_profile_Upper_Left.jpg',
    'test/_data/jpg/icc_profile_Upper_Right.jpg',
  ];

  group('issue #793 injectJpgExif', () {
    for (final path in jfifAndExifThumbnailFiles) {
      test('preserves JFIF APP0 and EXIF thumbnail: $path', () {
        final orig = File(path).readAsBytesSync();
        final exif = decodeJpgExif(orig);
        expect(exif, isNotNull, reason: 'test image must have EXIF');
        // Minimal edit, as described in the issue.
        exif!.imageIfd['DateTime'] = '2017:12:23 12:39:48';

        final out = injectJpgExif(orig, exif);
        expect(out, isNotNull, reason: 'injectJpgExif should return data');

        final origSegments = _segmentLayout(orig);
        final outSegments = _segmentLayout(out!);

        // Cause 1: the JFIF APP0 segment must survive the round-trip.
        expect(
          outSegments,
          contains(_Segment(JpegMarker.app0, isJfif: true)),
          reason: 'JFIF APP0 segment was dropped by injectJpgExif',
        );
        // Every segment that preceded the EXIF APP1 in the original must
        // still be present (and in the same order) before the rewritten
        // EXIF APP1 in the output.
        final origExifIndex = origSegments.indexWhere((s) => s.isExif);
        final outExifIndex = outSegments.indexWhere((s) => s.isExif);
        expect(
          origExifIndex,
          greaterThan(0),
          reason: 'original must have segments before the EXIF APP1',
        );
        expect(
          outSegments.sublist(0, outExifIndex),
          equals(origSegments.sublist(0, origExifIndex)),
          reason: 'segments preceding the EXIF APP1 must be preserved',
        );

        // Cause 2: the EXIF thumbnail must round-trip. The output EXIF block
        // must be large enough to actually contain the thumbnail payload
        // (it used to shrink to just the IFD entries, leaving the
        // ThumbnailOffset/ThumbnailLength tags pointing past the end).
        final decoded = decodeJpgExif(out);
        expect(decoded, isNotNull);
        expect(decoded!.thumbnail, isNotNull);
        expect(decoded.thumbnail!.length, greaterThan(0));

        // The thumbnail must be a valid JPEG (SOI..EOI) and its length must
        // match the JPEGInterchangeFormatLength tag (0x0202).
        final thumb = decoded.thumbnail!;
        expect(thumb.length, greaterThanOrEqualTo(2));
        expect(thumb[0], equals(0xff));
        expect(thumb[1], equals(0xd8)); // SOI
        expect(thumb[thumb.length - 2], equals(0xff));
        expect(thumb[thumb.length - 1], equals(0xd9)); // EOI

        final thumbLengthTag = decoded.thumbnailIfd[0x0202];
        expect(thumbLengthTag, isNotNull);
        expect(thumbLengthTag!.toInt(), equals(thumb.length));

        // The ThumbnailOffset tag (0x0201) must point *inside* the EXIF
        // block (i.e. before the end of the thumbnail payload), not past it.
        final thumbOffsetTag = decoded.thumbnailIfd[0x0201];
        expect(thumbOffsetTag, isNotNull);
        final thumbOffset = thumbOffsetTag!.toInt();
        expect(thumbOffset, greaterThan(0));
        expect(
          thumbOffset + thumb.length,
          lessThanOrEqualTo(_exifBlockPayloadLength(out)),
          reason: 'thumbnail offset/length must stay within the EXIF block',
        );
      });
    }

    test(
      'drops dangling thumbnail tags when no thumbnail payload is available',
      () {
        // Build an ExifData that *claims* to have a thumbnail via the offset/
        // length tags but carries no actual thumbnail bytes. This is the
        // situation that used to produce dangling pointers. After write+read
        // the tags must be gone (or point at real data) rather than dangling.
        final exif = ExifData()
          ..imageIfd['DateTime'] = '2017:12:23 12:39:48'
          ..thumbnailIfd[0x0201] = IfdValueLong(9999)
          ..thumbnailIfd[0x0202] = IfdValueLong(42);

        final out = OutputBuffer();
        exif.write(out);

        final decoded = ExifData()..read(InputBuffer(out.getBytes()));
        // No thumbnail bytes were provided, so the offset/length tags must be
        // dropped instead of being re-emitted as dangling pointers.
        expect(decoded.thumbnail, isNull);
        expect(decoded.thumbnailIfd.containsKey(0x0201), isFalse);
        expect(decoded.thumbnailIfd.containsKey(0x0202), isFalse);
      },
    );

    test('round-trips a thumbnail provided via the thumbnail field', () {
      // A tiny but valid JPEG: SOI + a fake APP0 + payload + EOI. Real
      // thumbnails are full JPEGs, but the EXIF code treats the payload as
      // opaque bytes.
      final thumbBytes = Uint8List.fromList([
        0xff, 0xd8, // SOI
        0xff, 0xe0, 0x00, 0x05, // fake APP0 segment
        0x01, 0x02, 0x03, // some payload
        0xff, 0xd9, // EOI
      ]);

      final exif = ExifData()
        ..thumbnail = thumbBytes
        ..imageIfd['DateTime'] = '2017:12:23 12:39:48';

      final out = OutputBuffer();
      exif.write(out);

      final decoded = ExifData()..read(InputBuffer(out.getBytes()));
      expect(decoded.thumbnail, isNotNull);
      expect(decoded.thumbnail!, equals(thumbBytes));
      // The offset/length tags must be consistent with the payload.
      expect(decoded.thumbnailIfd[0x0202]!.toInt(), equals(thumbBytes.length));
    });

    test('injectJpgExif preserves JFIF when adding a new EXIF block', () {
      // A JPEG with a JFIF APP0 but no EXIF block: injectJpgExif must add
      // the new EXIF APP1 while keeping the JFIF APP0 segment intact.
      final file = File('test/_data/jpg/jpgwithoutexifblock.jpg');
      final orig = file.readAsBytesSync();
      final origSegments = _segmentLayout(orig);
      expect(origSegments, contains(_Segment(JpegMarker.app0, isJfif: true)));
      expect(origSegments.any((s) => s.isExif), isFalse);

      final exif = ExifData()..imageIfd['DateTime'] = '2017:12:23 12:39:48';
      final out = injectJpgExif(orig, exif)!;

      final outSegments = _segmentLayout(out);
      // JFIF APP0 must still be present after the round-trip.
      expect(
        outSegments,
        contains(_Segment(JpegMarker.app0, isJfif: true)),
        reason: 'JFIF APP0 segment was dropped when adding a new EXIF block',
      );
      // And an EXIF APP1 must now be present.
      expect(outSegments.any((s) => s.isExif), isTrue);
    });

    test('injectJpgExif is a no-op-equivalent for the scan data', () {
      // The image scan data (SOS..EOI) must be byte-for-byte identical
      // before and after injectJpgExif: only the metadata segments change.
      final orig = File(
        'test/_data/jpg/icc_profile_data.jpg',
      ).readAsBytesSync();
      final exif = decodeJpgExif(orig)!;
      exif.imageIfd['DateTime'] = '2017:12:23 12:39:48';
      final out = injectJpgExif(orig, exif)!;

      final origScan = _scanData(orig);
      final outScan = _scanData(out);
      expect(
        outScan,
        equals(origScan),
        reason: 'image scan data must not be modified by injectJpgExif',
      );
    });
  });
}

/// Description of a top-level JPEG segment used by [_segmentLayout].
class _Segment {
  _Segment(this.marker, {this.isJfif = false, this.isExif = false});

  final int marker;
  final bool isJfif;
  final bool isExif;

  @override
  bool operator ==(Object other) =>
      other is _Segment &&
      marker == other.marker &&
      isJfif == other.isJfif &&
      isExif == other.isExif;

  @override
  int get hashCode => Object.hash(marker, isJfif, isExif);

  @override
  String toString() =>
      'Segment(0x${marker.toRadixString(16)}, jfif=$isJfif, exif=$isExif)';
}

/// Walks the JPEG markers and returns a list of segment descriptions, stopping
/// at the start of the scan data (SOS). Standalone markers (SOI, RSTn) are
/// skipped; only length-prefixed segments are reported.
List<_Segment> _segmentLayout(Uint8List jpeg) {
  final input = InputBuffer(jpeg, bigEndian: true);
  if (input.peekBytes(2)[0] != 0xff || input.peekBytes(2)[1] != 0xd8) {
    return const [];
  }
  var marker = _nextMarker(input);
  if (marker != JpegMarker.soi) return const [];
  final segments = <_Segment>[];
  marker = _nextMarker(input);
  while (marker != JpegMarker.eoi && !input.isEOS) {
    if (marker == JpegMarker.sos) {
      // Start of scan data: the rest is the image payload, stop here.
      break;
    }
    final length = input.readUint16();
    bool isJfif = false;
    bool isExif = false;
    if (marker == JpegMarker.app0) {
      isJfif = true;
    } else if (marker == JpegMarker.app1) {
      // Peek at the Exif signature without consuming it for real.
      if (length >= 6) {
        final sig = input.peekBytes(4);
        if (sig[0] == 0x45 &&
            sig[1] == 0x78 &&
            sig[2] == 0x69 &&
            sig[3] == 0x66) {
          isExif = true;
        }
      }
    }
    segments.add(_Segment(marker, isJfif: isJfif, isExif: isExif));
    input.skip(length - 2);
    marker = _nextMarker(input);
  }
  return segments;
}

/// Returns the raw scan data (from the SOS marker through EOI), i.e. the
/// actual compressed image bytes that must be untouched by injectJpgExif.
Uint8List _scanData(Uint8List jpeg) {
  final input = InputBuffer(jpeg, bigEndian: true);
  // Skip to SOS.
  var marker = _nextMarker(input);
  if (marker != JpegMarker.soi) return Uint8List(0);
  marker = _nextMarker(input);
  while (marker != JpegMarker.sos && !input.isEOS) {
    final length = input.readUint16();
    input.skip(length - 2);
    marker = _nextMarker(input);
  }
  if (marker != JpegMarker.sos) return Uint8List(0);
  // From the SOS marker onward (including the entropy-coded data and EOI) is
  // the scan payload.
  return Uint8List.fromList(
    jpeg.sublist(input.offset - 2),
  ); // include the SOS marker bytes
}

/// Returns the byte length of the EXIF APP1 payload (the bytes after the APP1
/// marker and length field) so thumbnail offset/length can be checked against
/// the actual block size.
int _exifBlockPayloadLength(Uint8List jpeg) {
  final input = InputBuffer(jpeg, bigEndian: true);
  var marker = _nextMarker(input);
  if (marker != JpegMarker.soi) return 0;
  marker = _nextMarker(input);
  while (marker != JpegMarker.eoi && !input.isEOS) {
    if (marker == JpegMarker.app1) {
      final length = input.readUint16();
      final sig = input.peekBytes(4);
      if (sig[0] == 0x45 &&
          sig[1] == 0x78 &&
          sig[2] == 0x69 &&
          sig[3] == 0x66) {
        // length includes the 2 length bytes themselves.
        return length - 2;
      }
      input.skip(length - 2);
    } else if (marker == JpegMarker.sos) {
      break;
    } else {
      final length = input.readUint16();
      input.skip(length - 2);
    }
    marker = _nextMarker(input);
  }
  return 0;
}

int _nextMarker(InputBuffer input) {
  var c = 0;
  if (input.isEOS) return c;
  do {
    do {
      c = input.readByte();
    } while (c != 0xff && !input.isEOS);
    if (input.isEOS) return c;
    do {
      c = input.readByte();
    } while (c == 0xff && !input.isEOS);
  } while (c == 0 && !input.isEOS);
  return c;
}
