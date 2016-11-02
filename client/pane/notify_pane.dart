import 'dart:html';
import 'dart:async';
import 'base_pane.dart';
import '../root/pane_key.dart';
import '../twotier/wtypes.dart';
import '../root/globals.dart';
import '../rpc_lib.dart';

///user notification pane - paneKey is 'notify/id'
class NotifyPane extends BasePane {
  PushQueueItem _item;

  @override
  Future init(PaneKey pk) async {
    //find already-loaded notification or throw exception
    await super.init(pk);
    String notifyId = pk.part1;
    _item = Globals.pushQueue.firstWhere((i) => i.sid == notifyId && i.kind == 'N', orElse: () => null);
    if (_item == null) return;

    //build pane
    buildSkeletonHtml2(paneClass: 'notify', iconHoverText: 'Notification', iconName: 'panenotify', title: _item.text);
    clearLoadingMessage();
    bodyElement.append(new DivElement() ..text = _item.text);
    bodyElement.append(new BRElement());
    var chk = new CheckboxInputElement();
    bodyElement.append(chk);
    bodyElement.appendText(' Dismiss ');
    if ((_item.linkPaneKey ?? '').length > 0) {
      bodyElement.appendText(' - ');
      var link = new AnchorElement() ..href = '#' + _item.linkPaneKey ..text = _item.linkText;
      bodyElement.append(link);
    }

    //events
    chk.onClick.listen((e) {
      chk.disabled = true;
      new Timer(new Duration(milliseconds: 300), () => chk.remove());
      dismiss();
    });
  }

  //send server message to dismiss notification
  void dismiss() {
    var req = new UserNotifySaveRequest();
    req.notifyId = _item.sid;
    RpcLib.command('UserNotifySave', req);
  }
}