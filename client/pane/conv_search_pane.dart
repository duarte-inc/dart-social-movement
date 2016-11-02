import 'dart:html';
import 'dart:async';
import 'base_pane.dart';
import '../twotier/wtypes.dart';
import '../root/pane_key.dart';
import '../rpc_lib.dart';
import '../lib/html_lib.dart';
import '../lib/form_builder.dart';
//import '../lib/button_bar_builder.dart';

///pane to allow searching for conversations and posts - paneKey is 'convs'
/// followed by optional /s=searchterm
class ConvSearchPane extends BasePane {
  DivElement _resultDiv;
  String _searchTerm;

  @override
  Future init(PaneKey pk) async {
    await super.init(pk);

    //build pane
    buildSkeletonHtml2(paneClass: 'convs', title: 'Conversation Search', iconName: 'paneconv');
    clearLoadingMessage();
    _resultDiv = HtmlLib.appendScrollingDiv(bodyElement) ..style.display = 'none';
    FormBuilder form = new FormBuilder(bodyElement, 'Criteria');
    InputElement termInp = form.addInput('Search term', 100, 50);

    //buttons
    paneMenuBar.addButton('Search', (e) {
      _searchTerm = trimInput(termInp);
      _doSearch();
    });

    //if search term provided in URL, search on it
    if (pk.length > 1) {
      String key1 = pk.part1;
      if (key1.startsWith('s=')) {
        _searchTerm = key1.substring(2);
        _doSearch();
      }
    }
  }

  //do the search and recreate _resultTable
  Future _doSearch() async {
    _resultDiv.style.display = 'block';
    _resultDiv.innerHtml = 'Loading...';
    ConvQueryResponse response = await RpcLib.convQuery(
      new ConvQueryRequest() ..term = _searchTerm);
    changePaneKey(new PaneKey('convs/s=' + _searchTerm));
    _resultDiv.innerHtml = '<h2>Conversations</h2>';
    for (ConvQueryConvItemResponse conv in response.convs) {
      DivElement itemDiv = new DivElement() ..className = 'space1';
      _resultDiv.append(itemDiv);
      HtmlLib.appendLinkToPane(itemDiv, conv.hitText, 'conv/${conv.convId}/h=${_searchTerm}');
      DivElement indented = new DivElement() ..style.marginLeft = HtmlLib.asPx(18);
      itemDiv.append(indented);
      for (ConvQueryPostItemResponse post in conv.posts) {
        indented.appendText(post.hitText);
        indented.appendHtml('<br/>');
      }
    }
    if (response.convs.length == 0) _resultDiv.innerHtml = '(none)';
  }
}
