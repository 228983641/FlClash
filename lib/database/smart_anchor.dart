part of 'database.dart';

@DataClassName('SmartAnchorRecord')
class SmartAnchorRecords extends Table {
  @override
  String get tableName => 'smart_anchor_records';

  TextColumn get key => text()();

  TextColumn get payload => text()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftAccessor(tables: [SmartAnchorRecords])
class SmartAnchorDao extends DatabaseAccessor<Database>
    with _$SmartAnchorDaoMixin {
  SmartAnchorDao(super.attachedDatabase);

  Future<List<SmartAnchorRecord>> all() {
    return smartAnchorRecords.readable((row) => row).get();
  }

  Future<void> put(String key, String payload, DateTime updatedAt) {
    return smartAnchorRecords.put(
      SmartAnchorRecordsCompanion.insert(
        key: key,
        payload: payload,
        updatedAt: updatedAt,
      ),
    );
  }

  Future<void> remove(String key) {
    return smartAnchorRecords.remove((t) => t.key.equals(key));
  }

  Future<void> removeWithPrefix(String prefix) {
    return smartAnchorRecords.remove((t) => t.key.like('$prefix%'));
  }
}
