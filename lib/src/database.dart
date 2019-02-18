import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:synchronized/synchronized.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'models.dart';

/// A class to handle database operations
class Db {
  Db();

  Database _db;

  final _mutex = new Lock();
  final StreamController<ChangeFeedItem> _changeFeedController =
      StreamController<ChangeFeedItem>.broadcast();
  File _dbFile;

  Stream<ChangeFeedItem> get changefeed => _changeFeedController.stream;
  File get file => _dbFile;
  // A Sqflite _db
  Database get database => _db;

  dispose() {
    _changeFeedController.close();
  }

  Future<void> init(
      {@required String path,
      List<String> queries: const <String>[],
      bool verbose: false,
      String fromAsset: ""}) async {
    /// initialize the database
    /// [path] the database file path relative to the documents directory
    /// [queries] list of queries to run at initialization
    /// [fromAsset] copy the database from an asset file
    /// [verbose] print info
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String dbpath = documentsDirectory.path + "/" + path;
    if (verbose == true) {
      print("INITIALIZING DATABASE at " + dbpath);
    }
    // copy the database from an asset if necessary
    if (fromAsset != "") {
      bool exists = await File(dbpath).exists();
      if (exists == false) {
        if (verbose == true) {
          print("Copying the database from asset $fromAsset");
        }
        try {
          // copy asset
          // read
          ByteData data = await rootBundle.load("$fromAsset");
          List<int> bytes =
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          // write
          await new File(dbpath).writeAsBytes(bytes);
        } catch (e) {
          throw ("Unable to copy database: $e");
        }
      }
    }
    if (this._db == null) {
      await _mutex.synchronized(() async {
        if (this._db == null) {
          // open
          if (verbose == true) {
            print("OPENING database");
          }
          this._db = await openDatabase(dbpath, version: 1,
              onCreate: (Database _db, int version) async {
            if (queries.length > 0) {
              for (String q in queries) {
                Stopwatch timer = Stopwatch()..start();
                await _db.execute(q);
                if (verbose == true) {
                  String msg = "$q  in ${timer.elapsedMilliseconds} ms";
                  print(msg);
                }
              }
            }
          });
        }
      });
    }
    // file
    _dbFile = File(dbpath);
  }

  Future<List<Map<String, dynamic>>> select(
      {@required String table,
      String columns = "*",
      String where,
      String orderBy,
      int limit,
      int offset,
      bool verbose: false}) async {
    /// select query
    /// [table] the table to select from
    /// [columns] the columns to return
    /// [where] the sql where clause
    /// [orderBy] the sql order_by clause
    /// [limit] the sql limit clause
    /// [offset] the sql offset clause
    /// [verbose] print the query
    /// returns the selected data
    try {
      Stopwatch timer = Stopwatch()..start();
      String q = "SELECT $columns FROM $table";
      if (where != null) {
        q += " WHERE $where";
      }
      if (orderBy != null) {
        q = "$q ORDER BY $orderBy";
      }
      if (limit != null) {
        q += " LIMIT $limit";
      }
      if (offset != null) {
        q += " OFFSET $offset";
      }
      final List<Map<String, dynamic>> res = await this._db.rawQuery(q);
      timer.stop();
      if (verbose == true) {
        String msg = "$q  in ${timer.elapsedMilliseconds} ms";
        print(msg);
      }
      return res.toList();
    } catch (e) {
      throw (e);
    }
  }

  Future<List<Map<String, dynamic>>> join(
      {@required String table,
      @required String joinTable,
      @required String joinOn,
      String columns = "*",
      int offset = 0,
      int limit = 100,
      String orderBy,
      String where,
      bool verbose}) async {
    /// select query with a join table
    /// [table] the table to select from
    /// [joinTable] the table to join from
    /// [joinOn] the columns to join
    /// [columns] the columns to return
    /// [where] the sql where clause
    /// [orderBy] the sql order_by clause
    /// [limit] the sql limit clause
    /// [offset] the sql offset clause
    /// [verbose] print the query
    /// returns the selected data
    try {
      Stopwatch timer = Stopwatch()..start();
      String q = "SELECT $columns FROM $table";
      q = "$q INNER JOIN $joinTable ON $joinOn";
      if (where != null) {
        q = q + " WHERE $where";
      }
      if (orderBy != null) {
        q = "$q ORDER BY $orderBy";
      }
      if (limit != null) {
        q += " LIMIT $limit";
      }
      if (offset != null) {
        q += " OFFSET $offset";
      }
      final List<Map<String, dynamic>> res = await this._db.rawQuery(q);
      timer.stop();
      if (verbose == true) {
        String msg = "$q  in ${timer.elapsedMilliseconds} ms";
        print(msg);
      }
      return res.toList();
    } catch (e) {
      throw (e);
    }
  }

  Future<void> insert(
      {@required String table,
      @required Map<String, String> row,
      bool verbose: false}) async {
    /// an insert query
    /// [table] the table to insert into
    /// [row] the data to insert
    /// [verbose] print the query
    await _mutex.synchronized(() async {
      Stopwatch timer = Stopwatch()..start();
      String fields = "";
      String values = "";
      int n = row.length;
      int i = 1;
      List<String> datapoint = [];
      for (var k in row.keys) {
        fields = "$fields$k";
        values = "$values?";
        datapoint.add(row[k]);
        if (i < n) {
          fields = "$fields,";
          values = "$values,";
        }
        i++;
      }
      String q = "INSERT INTO $table ($fields) VALUES($values)";
      this._db.rawInsert(q, datapoint).catchError((e) {
        throw (e);
      });
      String qStr = "$q $row";
      timer.stop();
      _changeFeedController.sink.add(ChangeFeedItem(
          changeType: "insert",
          value: 1,
          query: qStr,
          executionTime: timer.elapsedMicroseconds));
      if (verbose == true) {
        String msg = "$q  in ${timer.elapsedMilliseconds} ms";
        print(msg);
      }
    });
  }

  Future<int> update(
      {@required String table,
      @required Map<String, String> row,
      @required String where,
      bool verbose = false}) async {
    /// update some datapoints in the database
    /// [table] the table to use
    /// [row] the data to update
    /// [where] the sql where clause
    /// [verbose] print the query
    /// returns a count of the updated rows
    int updated = 0;
    await _mutex.synchronized(() async {
      Stopwatch timer = Stopwatch()..start();
      try {
        String pairs = "";
        int n = row.length - 1;
        int i = 0;
        List<String> datapoint = [];
        for (var el in row.keys) {
          pairs = "$pairs$el= ?";
          datapoint.add(row[el]);
          if (i < n) {
            pairs = "$pairs, ";
          }
          i++;
        }
        String q = 'UPDATE $table SET $pairs WHERE $where';
        updated = await this._db.rawUpdate(q, datapoint);
        String qStr = "$q $datapoint";
        timer.stop();
        _changeFeedController.sink.add(ChangeFeedItem(
            changeType: "update",
            value: updated,
            query: qStr,
            executionTime: timer.elapsedMicroseconds));
        if (verbose == true) {
          String msg = "$q  in ${timer.elapsedMilliseconds} ms";
          print(msg);
        }
        return updated;
      } catch (e) {
        throw (e);
      }
    });
    return updated;
  }

  Future<int> delete(
      {@required String table,
      @required String where,
      bool verbose: false}) async {
    /// delete some datapoints from the database
    /// [table] the table to use
    /// [where] the sql where clause
    /// [verbose] print the query
    /// returns a count of the deleted rows
    int deleted = 0;
    await _mutex.synchronized(() async {
      try {
        Stopwatch timer = Stopwatch()..start();
        String q = 'DELETE FROM $table WHERE $where';
        int deleted = await this._db.rawDelete(q);
        timer.stop();
        _changeFeedController.sink.add(ChangeFeedItem(
            changeType: "delete",
            value: deleted,
            query: q,
            executionTime: timer.elapsedMicroseconds));
        if (verbose == true) {
          String msg = "$q  in ${timer.elapsedMilliseconds} ms";
          print(msg);
        }
        return deleted;
      } catch (e) {
        throw (e);
      }
    });
    return deleted;
  }

  Future<bool> exists(
      {@required String table, @required String where, verbose: false}) async {
    /// check if a value exists in the table
    /// [table] the table to use
    /// [where] the where sql clause
    /// [verbose] print the query
    /// returns true if exists
    try {
      Stopwatch timer = Stopwatch()..start();
      String q = 'SELECT COUNT(*) FROM $table WHERE $where';
      int count = Sqflite.firstIntValue(await _db.rawQuery(q));
      timer.stop();
      if (verbose == true) {
        String msg = "$q  in ${timer.elapsedMilliseconds} ms";
        print(msg);
      }
      if (count > 0) {
        return true;
      }
    } catch (e) {
      throw (e);
    }
    return false;
  }

  Future<int> count(
      {@required String table, String where, bool verbose: false}) async {
    /// count rows in a table
    /// [table] the table to use
    /// [where] the sql where clause
    /// [verbose] print the query
    /// returns a count of the rows
    try {
      Stopwatch timer = Stopwatch()..start();
      String w = "";
      if (where != null) {
        w = " WHERE $where";
      }
      String q = 'SELECT COUNT(*) FROM $table$w';
      final num c = Sqflite.firstIntValue(await this._db.rawQuery(q));
      timer.stop();
      if (verbose == true) {
        String msg = "$q  in ${timer.elapsedMilliseconds} ms";
        print(msg);
      }
      return c;
    } catch (e) {
      throw (e);
    }
  }
}
