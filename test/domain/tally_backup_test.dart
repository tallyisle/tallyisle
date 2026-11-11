import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/zip_archive.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';

void main() {
  group('ZipArchive & IEEE 802.3 CRC-32', () {
    test('computes standard IEEE 802.3 CRC-32 vectors', () {
      expect(crc32(const <int>[]), 0x00000000);
      expect(crc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test(
      'round-trips STORED (0) and DEFLATE (8) entries with UTF-8 flag 0x0800',
      () {
        final storedPayload = Uint8List.fromList(utf8.encode('帐屿纯存储条目'));
        final deflatePayload = Uint8List.fromList(
          utf8.encode(List<String>.filled(80, '帐屿备份压缩测试_123456').join('\n')),
        );
        final emptyPayload = Uint8List(0);

        final encoded = ZipArchive.encode(<ZipEntry>[
          ZipEntry(
            name: 'manifest.json',
            bytes: storedPayload,
            method: ZipCompressionMethod.stored,
            modifiedAt: DateTime.utc(2026, 11, 6, 12, 0, 0),
          ),
          ZipEntry(
            name: 'attachments/发票_收据.jpg',
            bytes: deflatePayload,
            method: ZipCompressionMethod.deflate,
            modifiedAt: DateTime.utc(2026, 11, 6, 12, 0, 2),
          ),
          ZipEntry(
            name: 'attachments/empty.bin',
            bytes: emptyPayload,
            method: ZipCompressionMethod.deflate,
          ),
        ]);

        // Verify UTF-8 General Purpose Bit Flag 0x0800 in first Local File Header
        final headerView = ByteData.sublistView(encoded);
        expect(headerView.getUint32(0, Endian.little), 0x04034b50);
        expect(headerView.getUint16(6, Endian.little) & 0x0800, 0x0800);

        final decoded = ZipArchive.decode(encoded);
        expect(decoded.entries, hasLength(3));
        expect(decoded['manifest.json']!.bytes, storedPayload);
        expect(decoded['manifest.json']!.method, ZipCompressionMethod.stored);
        expect(decoded['attachments/发票_收据.jpg']!.bytes, deflatePayload);
        expect(
          decoded['attachments/发票_收据.jpg']!.method,
          ZipCompressionMethod.deflate,
        );
        expect(decoded['attachments/empty.bin']!.bytes, isEmpty);
      },
    );

    test('detects corrupted payload via CRC-32 mismatch', () {
      final raw = ZipArchive.encode(<ZipEntry>[
        ZipEntry(
          name: 'hello.txt',
          bytes: utf8.encode('immutable-payload-12345'),
          method: ZipCompressionMethod.stored,
        ),
      ]);

      final mutated = Uint8List.fromList(raw);
      // Local header is 30 bytes + 9 bytes ('hello.txt') = offset 39 is payload[0]
      mutated[39] ^= 0xFF;

      expect(
        () => ZipArchive.decode(mutated),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
    });

    test('rejects zip-slip path traversal on both encode and decode', () {
      for (final unsafe in <String>[
        '',
        '/etc/passwd',
        '../outside.txt',
        'attachments/../../secret.db',
        r'attachments\..\evil.txt',
        'C:/Windows/win.ini',
        'attachments//double_slash.jpg',
        'attachments/./dot.jpg',
      ]) {
        expect(
          () => validateZipEntryPath(unsafe),
          throwsA(isA<Failure>()),
          reason: 'Should reject unsafe path: $unsafe',
        );
      }

      // Also craft a raw ZIP buffer whose Central Directory name was mutated to '../evil.txt'
      final valid = ZipArchive.encode(<ZipEntry>[
        ZipEntry(
          name: 'abc/def.txt',
          bytes: ascii.encode('payload'),
          method: ZipCompressionMethod.stored,
        ),
      ]);
      final evilBytes = Uint8List.fromList(valid);
      final targetSeq = ascii.encode('abc/def.txt');
      final replacementSeq = ascii.encode('../evil.txt');
      for (var i = 0; i <= evilBytes.length - targetSeq.length; i++) {
        var match = true;
        for (var j = 0; j < targetSeq.length; j++) {
          if (evilBytes[i + j] != targetSeq[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          evilBytes.setRange(i, i + replacementSeq.length, replacementSeq);
        }
      }

      expect(
        () => ZipArchive.decode(evilBytes),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
    });
  });

  group('Lossless int64 minor-unit serialization (ADR-011, R2)', () {
    test(
      'serializes normal amounts as JSON int and >2^53-1 magnitudes as String',
      () {
        // Golden vector (docs/modules/backup-webdav.md §4): 100.50 yuan -> 10050
        final encodedNormal = encodeMinorJson(BigInt.from(10050));
        expect(encodedNormal, isA<int>());
        expect(encodedNormal, 10050);
        expect(
          decodeMinorJson(encodedNormal, field: 'money_minor'),
          BigInt.from(10050),
        );

        // Max signed int64 & min signed int64 exceed JS safe integer (2^53 - 1)
        final int64Max = BigInt.parse('9223372036854775807');
        final int64Min = BigInt.parse('-9223372036854775808');
        final unsafePositive = BigInt.parse('9007199254740993');

        final encodedMax = encodeMinorJson(int64Max);
        final encodedMin = encodeMinorJson(int64Min);
        final encodedUnsafe = encodeMinorJson(unsafePositive);
        expect(encodedMax, '9223372036854775807');
        expect(encodedMin, '-9223372036854775808');
        expect(encodedUnsafe, '9007199254740993');

        // JSON round-trip preserves every single bit
        final roundTripped =
            jsonDecode(
                  jsonEncode(<String, Object?>{
                    'normal': encodedNormal,
                    'normalAsStr': '10050',
                    'max': encodedMax,
                    'min': encodedMin,
                    'unsafe': encodedUnsafe,
                  }),
                )
                as Map<String, Object?>;

        expect(
          decodeMinorJson(roundTripped['normal'], field: 'normal'),
          BigInt.from(10050),
        );
        expect(
          decodeMinorJson(roundTripped['normalAsStr'], field: 'normalAsStr'),
          BigInt.from(10050),
        );
        expect(decodeMinorJson(roundTripped['max'], field: 'max'), int64Max);
        expect(decodeMinorJson(roundTripped['min'], field: 'min'), int64Min);
        expect(
          decodeMinorJson(roundTripped['unsafe'], field: 'unsafe'),
          unsafePositive,
        );
      },
    );

    test(
      'strictly rejects floating-point numbers and out-of-range BigInts',
      () {
        expect(
          () => decodeMinorJson(100.5, field: 'money_minor'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );
        expect(
          () => decodeMinorJson('100.50', field: 'money_minor'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );
        expect(
          () => decodeMinorJson('9223372036854775808', field: 'money_minor'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );
      },
    );
  });

  group(
    '.tally pack, manifest verification & tamper detection (§2.2, R1..R5, §4)',
    () {
      test(
        'packs all 22 tables + attachments and verifies SHA-256 on unpack',
        () {
          expect(tallyBusinessTables, hasLength(22));
          expect(
            tallyBusinessTables,
            containsAll(<String>['note', 'currency']),
          );

          final jpgBytes = Uint8List.fromList(<int>[
            0xFF,
            0xD8,
            0xFF,
            0xE0,
            1,
            2,
            3,
          ]);
          final pngBytes = Uint8List.fromList(<int>[
            0x89,
            0x50,
            0x4E,
            0x47,
            4,
            5,
            6,
          ]);

          final packed = packTallyArchive(
            tables: <String, List<Map<String, Object?>>>{
              'account_book': <Map<String, Object?>>[
                <String, Object?>{'id': 1, 'name': '日常账本', 'create_date': 1000},
              ],
              'record': <Map<String, Object?>>[
                <String, Object?>{
                  'record_id': 'r1',
                  'type': 0,
                  'money_minor': encodeMinorJson(BigInt.from(10050)),
                  'record_time': 2000,
                  'account_book_id': 1,
                },
              ],
              'note': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 1,
                  'title': '便签1',
                  'content': '重要事项',
                  'create_time': 100,
                  'update_time': 200,
                },
              ],
              'currency': <Map<String, Object?>>[
                <String, Object?>{
                  'code': 'USD',
                  'name': '美元',
                  'symbol': r'$',
                  'rate_to_anchor': '7.25',
                  'anchor_code': 'CNY',
                },
              ],
            },
            attachments: <String, Uint8List>{
              '7a8b9c0d1e2f.jpg': jpgBytes,
              'attachments/e3f1a2b4c5d6.png': pngBytes,
            },
            createdAtMs: 1793952000000,
          );

          expect(packed.manifest.formatVersion, 1);
          expect(packed.manifest.appName, 'TallyIsle');
          expect(packed.manifest.schemaVersion, 42);
          expect(packed.manifest.tableCounts.keys, hasLength(22));
          expect(packed.manifest.recordCount, 1);
          expect(packed.manifest.noteCount, 1);
          expect(packed.manifest.currencyCount, 1);
          expect(packed.manifest.attachmentCount, 2);

          final verified = unpackAndVerifyTallyArchive(packed.bytes);
          expect(verified.tables.keys, hasLength(22));
          expect(
            verified.attachments['attachments/7a8b9c0d1e2f.jpg'],
            jpgBytes,
          );
          expect(
            verified.attachments['attachments/e3f1a2b4c5d6.png'],
            pngBytes,
          );
        },
      );

      test(
        'lightweight mode (includeAttachments: false) omits attachments while keeping 22 tables (§6.3)',
        () {
          final packed = packTallyArchive(
            tables: <String, List<Map<String, Object?>>>{
              'note': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 1,
                  'content': '纯数据模式',
                  'create_time': 1,
                  'update_time': 1,
                },
              ],
            },
            attachments: <String, Uint8List>{
              'heavy_photo.jpg': Uint8List.fromList(List<int>.filled(1024, 42)),
            },
            createdAtMs: 1793952000000,
            includeAttachments: false,
          );

          expect(packed.manifest.includeAttachments, isFalse);
          expect(packed.manifest.filesChecksum, isEmpty);

          final verified = unpackAndVerifyTallyArchive(packed.bytes);
          expect(verified.attachments, isEmpty);
          expect(verified.tables['note'], hasLength(1));
        },
      );

      test(
        'Golden Vector: rejects tampered database.json via database_sha256 check',
        () {
          final packed = packTallyArchive(
            tables: <String, List<Map<String, Object?>>>{
              'record': <Map<String, Object?>>[
                <String, Object?>{
                  'record_id': 'r1',
                  'type': 0,
                  'money_minor': 10050,
                  'record_time': 1000,
                  'account_book_id': 1,
                },
              ],
            },
            createdAtMs: 1793952000000,
          );

          final origZip = ZipArchive.decode(packed.bytes);
          final tamperedDbText = utf8
              .decode(origZip['database.json']!.bytes)
              .replaceFirst('10050', '99999');

          final reEncodedZip = ZipArchive.encode(<ZipEntry>[
            origZip['manifest.json']!,
            ZipEntry(name: 'database.json', bytes: utf8.encode(tamperedDbText)),
          ]);

          expect(
            () => unpackAndVerifyTallyArchive(reEncodedZip),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.corruptData,
              ),
            ),
          );
        },
      );

      test(
        'rejects tampered attachment bytes and unlisted rogue attachments',
        () {
          final packed = packTallyArchive(
            tables: const <String, List<Map<String, Object?>>>{},
            attachments: <String, Uint8List>{
              'receipt.jpg': Uint8List.fromList(<int>[1, 2, 3, 4]),
            },
            createdAtMs: 1793952000000,
          );
          final origZip = ZipArchive.decode(packed.bytes);

          final tamperedAttachmentZip = ZipArchive.encode(<ZipEntry>[
            origZip['manifest.json']!,
            origZip['database.json']!,
            ZipEntry(
              name: 'attachments/receipt.jpg',
              bytes: Uint8List.fromList(<int>[1, 2, 3, 99]),
            ),
          ]);
          expect(
            () => unpackAndVerifyTallyArchive(tamperedAttachmentZip),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.corruptData,
              ),
            ),
          );

          final rogueAttachmentZip = ZipArchive.encode(<ZipEntry>[
            origZip['manifest.json']!,
            origZip['database.json']!,
            origZip['attachments/receipt.jpg']!,
            ZipEntry(
              name: 'attachments/rogue.png',
              bytes: Uint8List.fromList(<int>[7, 8, 9]),
            ),
          ]);
          expect(
            () => unpackAndVerifyTallyArchive(rogueAttachmentZip),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.corruptData,
              ),
            ),
          );
        },
      );
    },
  );

  group('Retention pruning, active book resolution & R7 silent auto-backup', () {
    test(
      'resolveRestoredActiveBookId chooses 1 if present else first sorted book',
      () {
        expect(
          resolveRestoredActiveBookId(<({int id, int sort})>[
            (id: 5, sort: 0),
            (id: 1, sort: 3),
          ]),
          1,
        );
        expect(
          resolveRestoredActiveBookId(<({int id, int sort})>[
            (id: 9, sort: 2),
            (id: 4, sort: 1),
          ]),
          4,
        );
        expect(resolveRestoredActiveBookId(const <({int id, int sort})>[]), 1);
      },
    );

    test(
      'selectBackupsToPrune keeps newest 10 by default and returns older ones',
      () {
        final all = <BackupRetentionItem>[
          for (var i = 1; i <= 13; i++)
            BackupRetentionItem(
              fileName:
                  'backup_202611${i.toString().padLeft(2, '0')}_120000.tally',
              modifiedAtMs: i * 1000,
            ),
        ];
        final pruned = selectBackupsToPrune(all);
        expect(pruned, <String>[
          'backup_20261103_120000.tally',
          'backup_20261102_120000.tally',
          'backup_20261101_120000.tally',
        ]);
      },
    );

    test(
      'shouldTriggerAutoBackup enforces enabled && configured && changed && >=24h (R7)',
      () {
        const t0 = 1793952000000;
        const h23 = 23 * 60 * 60 * 1000;
        const h24 = 24 * 60 * 60 * 1000;

        expect(
          shouldTriggerAutoBackup(
            enabled: false,
            webDavConfigured: true,
            localDataChanged: true,
            lastBackupAtMs: t0,
            nowMs: t0 + h24,
          ),
          isFalse,
        );
        expect(
          shouldTriggerAutoBackup(
            enabled: true,
            webDavConfigured: false,
            localDataChanged: true,
            lastBackupAtMs: t0,
            nowMs: t0 + h24,
          ),
          isFalse,
        );
        expect(
          shouldTriggerAutoBackup(
            enabled: true,
            webDavConfigured: true,
            localDataChanged: false,
            lastBackupAtMs: t0,
            nowMs: t0 + h24 + 5000,
          ),
          isFalse,
        );
        expect(
          shouldTriggerAutoBackup(
            enabled: true,
            webDavConfigured: true,
            localDataChanged: true,
            lastBackupAtMs: t0,
            nowMs: t0 + h23,
          ),
          isFalse,
        );
        expect(
          shouldTriggerAutoBackup(
            enabled: true,
            webDavConfigured: true,
            localDataChanged: true,
            lastBackupAtMs: t0,
            nowMs: t0 + h24,
          ),
          isTrue,
        );
      },
    );
  });
}
