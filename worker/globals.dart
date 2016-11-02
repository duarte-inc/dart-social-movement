import 'dart:math';
import 'server/config.dart';

///stores worker globals
class Globals {

  ///config file settings
  static Config config = new Config();

  //timing
  static DateTime next30s = new DateTime(1970);
  static DateTime next1h = new DateTime(1970);
  static DateTime next24h = new DateTime(1970);
  static DateTime next1week = new DateTime(1970);

  //debugging
  static Random random = new Random(new DateTime.now().millisecondsSinceEpoch);
  static String logFileSuffix = (random.nextInt(9000) + 999).toString() + '.txt'; //such as '1234.txt'
}
