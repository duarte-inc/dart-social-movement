import 'dart:async';
import 'package:angel_framework/angel_framework.dart';
import 'package:http_parser/http_parser.dart';
import 'package:autzone_common/autzone_common.dart';

///http handlers for hard links such as those included in emails
class Linkback {

  //validate email address for user id; see xuser.proposed_email field for
  // explanation. Url is /linkback/ValidateEmail?id=1&code=abc
  static Future validateEmail(RequestContext req, ResponseContext resp) async {
    await Database.safely('ValidateEmail', (db) async {

      //get params
      Map params = req.uri.queryParameters;
      String idString = params['id'];
      int id = int.parse(idString);
      String code = params['code'];

      bool ok = false;
      int siteId;
      String finalMessage = null;
      String email = null, actualCode = null;

      //load proposed_email and unpack
      final row = await MiscLib.queryRow(db, 'select proposed_email, site_id from xuser where id=@i',
        {'i':id});
      if (row != null) {
        siteId = row['site_id'];
        final proposedEmail = MiscLib.jsonToMap(row['proposed_email']);
        if (proposedEmail != null) {
          email = proposedEmail['email'];
          actualCode = proposedEmail['code'];
          ok = email != null && actualCode != null;
        }
      }

      //if code matches, set new email
      if (ok) {
          if (code == actualCode) {
            try {
              await db.execute('update xuser set proposed_email=null,email=@e where id=${id}', substitutionValues: {'e': email});
            }
            catch (ex) {
              ok = false; //duplicate email
              finalMessage = 'The email address is associated with another account and could not be used for this account.';
            }
          } else {
            ok = false;
          }
      }

      //compose html response
      String pageHtml = ok ? 'Email successfully updated.' : (finalMessage ?? 'Page called in error.');
      await _commonResponse(siteId, resp, pageHtml);
    });//safely
  }

  //writes content and closes req, where body is plain text or html;
  //this gets wrapped in html+body tags
  static Future _commonResponse(int siteId, ResponseContext resp, String body) async {
    final site = await ApiGlobals.instance.sites.byId(siteId);
    String homeUrl = site.homeUrl;
    String siteName = site.title1;
    String page = '<html><body>' + body
      + '<hr />Close this tab, or continue to <a href="${homeUrl}">${siteName}</a></body></html>';

    resp.contentType = MediaType('text', 'html');
    resp.write(page);
    await resp.close();
  }
}
