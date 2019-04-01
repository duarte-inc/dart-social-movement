import 'dart:async';
import 'dart:io';
import 'worker_globals.dart';
import 'package:autzone_common/autzone_common.dart';
import 'package:autzone_models/autzone_models.dart';
import 'wdatabase.dart';

///controls access to all the worker tasks on a timer
class Controller {

  ///start all tasks
  Future start() async {
    final aSecond = new Duration(seconds:1);
    await writeAliveFile(true);

    //infinite loop
    while (true) {
      //exit if stop file exists
      File stopFile = new File(ConfigLoader.rootPath() + '/status/stop.txt');
      if (await stopFile.exists()) {
        ApiGlobals.configLoader.stopWatching();
        await writeAliveFile(false);
        return;
      }

      await _timerTick();
      sleep(aSecond);
    }
  }

  ///do tasks scheduled for right now
  Future _timerTick() async {
    DateTime now = WLib.utcNow();
    if (now.isAfter(WorkerGlobals.next30s)) {
      await writeAliveFile(true);
      await WDatabase.safely('findUnreads', WDatabase.findUnreads);
      await WDatabase.safely('smallSiteAccelerate', WDatabase.smallSiteAccelerate);
      WorkerGlobals.next30s = WLib.utcNow().add(new Duration(seconds:30));
    } else if (now.isAfter(WorkerGlobals.next1h)) {
      await WDatabase.safely('timeoutProposals', WDatabase.timeoutProposals);
      await WDatabase.safely('calcReactions', WDatabase.recalcReactions);
      await WDatabase.safely('countResourceVotes', WDatabase.countResourceVotes);
      await WDatabase.safely('recommendConversations', WDatabase.recommendConversations);
      WorkerGlobals.next1h = WLib.utcNow().add(new Duration(hours:1));
    } else if (now.isAfter(WorkerGlobals.next24h)) {
      await WDatabase.safely('loadDailyGlobals', WDatabase.loadDailyGlobals);
      await WDatabase.safely('dailyDelete', WDatabase.dailyDelete);
      await WDatabase.safely('assignProjectLeadership', WDatabase.assignProjectLeadership);
      await WDatabase.safely('closeConversations', WDatabase.closeConversations);
      await WDatabase.safely('hideResources', WDatabase.hideResources);
      await WDatabase.safely('emailNotifications', WDatabase.emailNotifications);
      await WDatabase.safely('countProjectImportance', WDatabase.countProjectImportance);
      WorkerGlobals.next24h = WLib.utcNow().add(new Duration(days:1));
    } else if (now.isAfter(WorkerGlobals.next1week)) {
      await WDatabase.safely('weeklyDelete', WDatabase.weeklyDelete);
      await WDatabase.safely('assignSiteLeadership', WDatabase.assignSiteLeadership);
      WorkerGlobals.next1week = WLib.utcNow().add(new Duration(days:7));
    }
  }

  ///write to worker_alive.txt so the supervisor can detect if this process is running
  Future writeAliveFile(bool makeExist) async {
    try {
      File f = new File(ConfigLoader.rootPath() + '/status/worker_alive.txt');
      if (makeExist){
        await f.writeAsString("!");
      } else {
        await f.delete();
      }
    }
    catch (ex) {
      await Logger.logLimited('worker_debug_', 'could not write to worker_alive, ' + ex.toString());
    }

    //for debugging also write *alive file with unique name for this process
    try {
      File f = new File(ConfigLoader.rootPath() + '/status/worker_alive' + WorkerGlobals.logFileSuffix);
      if (makeExist){
        await f.writeAsString("!");
      } else {
        await f.delete();
      }
    }
    catch (ex) {
    }

  }
}
