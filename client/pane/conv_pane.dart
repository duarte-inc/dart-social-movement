import 'dart:html';
import 'dart:async';
import 'base_pane.dart';
import '../pane_factory.dart';
import '../push_queue_handler.dart';
import '../root/globals.dart';
import '../twotier/wtypes.dart';
import '../twotier/wlib.dart';
import '../rpc_lib.dart';
import '../messages.dart';
import '../root/pane_key.dart';
import '../lib/html_lib.dart';
import '../dialog/image_upload_dialog.dart';
import '../lib/card_builder.dart';
import '../lib/button_bar_builder.dart';
import '../lib/string_dialog.dart';
import '../dialog/confirm_dialog.dart';
import '../dialog/conv_dialog.dart';

///conversation read/reply pane
/// pane key = 'conv/id/h=hilite_term', h= part optional
class ConvPane extends BasePane {
  int _convId;
  ConvGetResponse _conv; //data from server
  String _hilite; //the term to hilight from panekey
  bool _isJoined = false, _isManager = false;
  DivElement _postDiv = new DivElement(); //parent for posts
  DivElement _postExpandBox; //null or the currently visible post expand box
  DivElement _postExpandBoxForPost; //the .post div that _postExpandBox applies to
  String _autoReadPositionKey; //if non-null, an action with this key was added to Globals.doOnUserAction
  Map<ConvGetPostItem, Element> postElements = new Map<ConvGetPostItem, Element>(); //all rendered posts
  //note that postElements get added to client side when the user posts something, but that element is fully filled in
  ConvGetPostItem _lastPost; //last post rendered or null (not including the one created client side)

  /*
   * Notes on DOM structure: bodyElement has a top card, the posts (_postDiv) and
   * the reply section. Within _postDiv are the following elements, interspersed:
   * - .post
   * - .post-expand-wrap: there is one after each post
   * - controls to load already-read posts (positioned where they will be loaded)
   * - .post-expand-box: there is at most one of these, positioned after the
   *      .post-expand-wrap
   */
  @override
  Future init(PaneKey pk) async {
    //parse pane key
    _convId = pk.part1AsInt;
    if (pk.length > 2) {
      String part2 = pk.part(2);
      if (part2.startsWith('h=')) _hilite = part2.substring(2);
    }
    await super.init(pk);

    //get conversation and posts
    _conv = await RpcLib.convGet(new ConvGetRequest() ..convId = _convId ..mode = 'U');
    _isJoined = _conv.isJoined == 'Y';
    _isManager = _conv.isManager == 'Y';

    //build pane top part
    buildSkeletonHtml2(paneClass: 'conv', iconHoverText: 'Conversation', iconName: 'paneconv', title: _conv.title,
      subtitle: 'in project: ${_conv.parentTitle}', subtitlePaneKey: _conv.parentPaneKey);
    clearLoadingMessage();
    CardBuilder card = new CardBuilder(bodyElement);
    card.addText('Title', _conv.title);
    if (!_isJoined) card.addText('Joined', 'You have not yet joined this conversation');
    if (_conv.deleteMessage != null) card.addText('Status', _conv.deleteMessage);

    //build posts
    bodyElement.append(_postDiv);
    int postNo = 0;
    for (ConvGetPostItem post in _conv.posts) {
      _appendOnePost(post, true);
      if (!_isJoined) break; //if not joined, can only see opener
      if (postNo == 0 && _conv.anySkipped == 'Y')
        _appendMissingPosts(); //only after opening post
      ++postNo;
      _lastPost = post;
    }

    //build reply area and buttons
    if (_conv.replyAllowed == 'Y') {
      _buildReplyControls();
    } else {
      //if reply not allowed, put instructions at this level (if reply is allowed,
      // instructions will get put inside the reply controls box)
      DivElement replyAllowed = new DivElement() ..text = _conv.replyAllowedDesc ..className = 'instruct';
      bodyElement.append(replyAllowed);
    }
    _buildMainButtonBar();

    //if read position is not at the end, set up deferred behavior to update the
    //read position. This will get run on the next pane display, but if the user
    //closes the browser then it won't get run (which is desired so that that
    // those posts remain unread)
    if (_conv.posts.length > 0) {
      DateTime lastpos = WLib.wireToDateTime(_conv.posts.last.createdAtWDT);
      DateTime readpos = WLib.wireToDateTime(_conv.readPositionWDT);
      if (readpos.isBefore(lastpos)) {
        var action = () {
          _resetReadDotImages(lastpos);
          RpcLib.command('ConvSetReadPosition', new ConvSetReadPositionRequest()
            ..convId = _convId ..positionWDT = WLib.dateTimeToWire(lastpos));
        };
        _autoReadPositionKey = 'c${_convId}_readpos';
        Globals.doOnUserAction[_autoReadPositionKey] = action;
      }
    }
  }

  ///appends the given post to _postDiv, optionally inserting it after afterElement
  /// (which may be a .post, and it skips the expand-wrap following it)
  Element _appendOnePost(ConvGetPostItem post, bool isFromServer, {Element afterElement}) {
    DateTime createdAt = WLib.wireToDateTime(post.createdAtWDT),
      readPos = WLib.wireToDateTime(_conv.readPositionWDT);
    bool isUnread = isFromServer && createdAt.isAfter(readPos);

    DivElement postEl = new DivElement() ..className = 'post';
    if (afterElement == null) _postDiv.append(postEl);
    else {
      Element ewrap = afterElement.nextElementSibling;
      if (ewrap != null && ewrap.classes.contains('post-expand-wrap'))
        afterElement = ewrap;
      afterElement.insertAdjacentElement('afterEnd', postEl);
    }
    postElements[post] = postEl;

    //read/unread dot
    DivElement readDot;
    if (isFromServer) {
      readDot = new DivElement() ..className = 'read-dot';
      postEl.append(readDot);
      String readDotImageName = isUnread ? 'unread-dot.png' : 'read-dot.png';
      readDot.appendHtml('<img src="images/${readDotImageName}" title="Set read/unread"/>');

      //avatar, nick, ago
      DivElement avatar = new DivElement() ..className = 'avatar';
      postEl.append(avatar);
      if (post.avatarUrl != null)
        avatar.append(new ImageElement(src: post.avatarUrl));
      AnchorElement nick = new AnchorElement() ..className = 'nick'
        ..text = post.authorNick
        ..href = '#user/${post.authorId}';
      postEl.append(nick);
      SpanElement ago = new SpanElement() ..className = 'ago' ..text = post.ago;
      postEl.append(ago);
      //postEl.appendText(': ');
    }

    //post text
    _appendCollapsedPostText(post, postEl);

    //image
    if (post.imageUrl != null && post.imageUrl.length > 0) {
      postEl.append(new ImageElement(src: post.imageUrl) ..className = 'post-image');
    }

    //expansion arrow (note this is not inside postEl)
    DivElement expandWrap, expand;
    ImageElement expandImg;
    if (isFromServer) {
      expandWrap = new DivElement() ..className = 'post-expand-wrap';
      expand = new DivElement() ..className = 'post-expand' ..title = 'Options for this post';
      expandImg = new ImageElement() ..src = 'images/post-expand.png';
      expand.append(expandImg);
      postEl.insertAdjacentElement('afterEnd', expandWrap);
      afterElement = expandWrap;
      expandWrap.append(expand);
    }

    //hook up events on read-dot and expander
    if (expand != null) {
      expand.onClick.listen((e) {
        if (_postExpandBoxForPost == postEl) {
          _removePostExpandBox();
        } else {
          expandImg.src = 'images/post-collapse.png';
          _buildPostExpandBox(post, postEl);
        }
      });
    }
    if (readDot != null) {
      readDot.onClick.listen((e) async {
        DateTime readpos = WLib.wireToDateTime(post.createdAtWDT);
        if (isUnread) {
          //advance read position
          //(readpos stays as above)
        } else {
          //back up read position
          readpos = readpos.subtract(new Duration(milliseconds: 1));
        }
        _resetReadDotImages(readpos);
        await RpcLib.command('ConvSetReadPosition', new ConvSetReadPositionRequest()
          ..convId = _convId ..positionWDT = WLib.dateTimeToWire(readpos));
        Globals.doOnUserAction.remove(_autoReadPositionKey); //cancel auto-advance read position
      });
    }

    return postEl;
  }

  ///reset the color of all read-dots based on the new read position
  void _resetReadDotImages(DateTime readpos) {
    postElements.forEach((post, div) {
      DateTime createdAt = WLib.wireToDateTime(post.createdAtWDT);
      bool isUnread = createdAt.isAfter(readpos);
      String readDotImageName = isUnread ? 'unread-dot.png' : 'read-dot.png';
      ImageElement dot = div.querySelector('.read-dot img');
      dot.src = 'images/${readDotImageName}';
    });
  }

  ///remove post expanded control box if it was displayed, and insert it for the given
  /// post as the sibling following postEl
  Future _buildPostExpandBox(ConvGetPostItem post, Element postEl) async {
    _removePostExpandBox();

    //build the expansion with info available now
    postEl.classes.add('expanded');
    _postExpandBox = new DivElement() ..className = 'post-expand-box';
    _postExpandBox.append(new HRElement());
    DivElement createdAtDiv = new DivElement() ..text = 'Posted...';
    _postExpandBox.append(createdAtDiv);
    DivElement throttleDiv = new DivElement();
    _postExpandBox.append(throttleDiv);
    _postExpandBox.append(new HRElement());
    CheckboxInputElement inappropriateCheck = new CheckboxInputElement() ..disabled = true;
    _postExpandBox.append(new DivElement() ..append(inappropriateCheck) ..appendText(' Inappropriate'));
    ButtonBarBuilder btns = new ButtonBarBuilder(_postExpandBox);

    //add to DOM
    postEl.nextElementSibling.insertAdjacentElement('afterEnd', _postExpandBox);
    _postExpandBoxForPost = postEl;

    //hook up events on controls; add buttons
    inappropriateCheck.onChange.listen((e) async {
      _inappropriateClicked(post, inappropriateCheck.checked);
    });
    btns.addButton('New Conversation From Here', (e) async {
      ConvDialog dlg = new ConvDialog.spawn(_convId, post.id, post.ptext);
      int spawnedConvId = await dlg.show();
      PaneFactory.createFromString('conv/${spawnedConvId}');
    });

    //get more info about post from server
    ConvPostGetResponse moreInfo = await RpcLib.convPostGet(new ConvPostGetRequest() ..postId = post.id);

    //modify the box with the newly fetched info
    createdAtDiv.text = 'Posted on ' + moreInfo.createdAtReadable;
    if ((moreInfo.throttleDescription ?? '').length > 0)
      throttleDiv.text = moreInfo.throttleDescription + ' ';
    if ((moreInfo.allReasons ?? '').length > 0)
      throttleDiv.appendText('This post was considered inappropriate, and the following reasons were given: ' + moreInfo.allReasons);
    if (moreInfo.reaction == 'X') inappropriateCheck.checked = true;
    inappropriateCheck.disabled = false;

    //add delete button if this is my own post or user has censor authority
    bool isOwnPost = post.authorId == Globals.userId;
    bool canCensor = moreInfo.canCensor == 'Y';
    if (isOwnPost || canCensor) {
      btns.addButton('Delete Post', (e) async {
        _deletePostClicked(post, postEl, moreInfo);
      });
    }
  }

  ///remove post expanded control box if any
  void _removePostExpandBox() {
    //remove expanded controls
    if (_postExpandBox != null) {
      _postExpandBox.remove();
      _postExpandBox = null;
    }

    //change collapse image to expand image
    if (_postExpandBoxForPost != null) {
      _postExpandBoxForPost.classes.remove('expanded');
      Element expandWrap = _postExpandBoxForPost.nextElementSibling;
      if (expandWrap.classes.contains('post-expand-wrap')) { //should always be this
        ImageElement img = expandWrap.querySelector('img');
        img.src = 'images/post-expand.png';
      }
      _postExpandBoxForPost = null;
    }
  }

  ///handle deleting or censoring a post
  Future _deletePostClicked(ConvGetPostItem post, Element postEl, ConvPostGetResponse postInfo) async {
    //confirm deletion
    ConfirmDialog conf = new ConfirmDialog('Really delete post?', ConfirmDialog.YesNoOptions);
    int btnIdx = await conf.show();
    if (btnIdx != 0) return;

    bool isOwnPost = post.authorId == Globals.userId;

    //prep server request
    ConvPostSaveRequest deleteReq = new ConvPostSaveRequest()
      ..convId = _convId
      ..postId = post.id;
    if (isOwnPost)
      deleteReq.delete = 'Y';
    else {
      deleteReq.censored = 'C';
      deleteReq.ptext = 'Post deleted by: ' + Globals.nick;
    }

    //remove from DOM
    _removePostExpandBox();
    Element expandWrap = postEl.nextElementSibling;
    if (expandWrap.classes.contains('post-expand-wrap'))
      expandWrap.remove();
    postEl.remove();

    //notify server
    await RpcLib.command('ConvPostSave', deleteReq);
  }

  ///handle inappropriate checkbox
  Future _inappropriateClicked(ConvGetPostItem post, bool isChecked) async {
    String reason = '';
    if (isChecked) {
      StringDialog dlg = new StringDialog('Enter reason for flagging this post', '', 50);
      reason = await dlg.show();
    }
    await RpcLib.command('ConvPostUserSave', new ConvPostUserSaveRequest()
      ..postId = post.id
      ..reason = reason
      ..reaction = isChecked ? 'X' : ''
    );
  }

  ///append the post text with an expansion link of the right kind
  void _appendCollapsedPostText(ConvGetPostItem post, Element parent) {
    DivElement div = new DivElement();
    parent.append(div);
    String mode = post.collapseMode;
    int pos = post.collapsePosition;
    String expandLinkText = 'More';
    bool hideInitial = mode != 'Normal'; //if there is any kind of warning, hide it when the user expands
    if (mode == 'AuthorBlocked') expandLinkText = 'Show content from blocked author';
    else if (mode == 'PostInappropriate') expandLinkText = 'View inappropriate content';
    else if (mode == 'UserSuspcicious') expandLinkText = 'View possibly inappropriate content';
    else if (mode == 'Trigger') expandLinkText = 'Continue past trigger warning';
    HtmlLib.insertCollapsed1(div, post.ptext, collapsePosition: pos, moreMessage: expandLinkText,
      hideInitial: hideInitial);

    //change html in DOM to highlight the search term if provided
    if (_hilite != null) {
      //TODO hilight
    }
  }

  ///appends the expander button to _postDiv (for loading already-read posts)
  void _appendMissingPosts() {
    //insert button
    ButtonElement expander = new ButtonElement()
      ..text = 'Show older posts';
    _postDiv.append(expander);

    //click: fetch range of missing posts and insert them;
    //this assumes that the button is placed between posts[0] and [1]
    expander.onClick.listen((e) async {
      if (_conv.posts.length < 2) return;
      Element openingElement = expander.previousElementSibling;
      expander.remove();
      ConvGetRequest req = new ConvGetRequest()
        ..convId = _convId
        ..mode = 'R'
        ..rangeFromWDT = _conv.posts[0].createdAtWDT
        ..rangeToWDT = _conv.posts[1].createdAtWDT;
      ConvGetResponse conv2 = await RpcLib.convGet(req);
      Element priorElement;
      for (ConvGetPostItem post in conv2.posts) {
        priorElement = _appendOnePost(post, true, afterElement: priorElement ?? openingElement);
      }
    });
  }

  ///append the reply controls to bodyElement
  void _buildReplyControls() {
    //reply text area always shown but increases height when nonempty
    TextAreaElement replyInp = new TextAreaElement()
      ..rows = 1
      ..placeholder = 'Reply...'
      ..maxLength = _conv.replyMaxLength
      ..style.width = '100%';
    if (_conv.posts.length == 0) replyInp.placeholder = 'Start conversation';
    bodyElement.append(replyInp);
    replyInp.focus();

    //detail controls are only shown when reply is nonempty
    DivElement postControlsBox = new DivElement() ..style.display = 'none';
    bool isExpanded = false;
    bodyElement.append(postControlsBox);
    DivElement replyAllowed = new DivElement() ..text = _conv.replyAllowedDesc ..className = 'instruct';
    postControlsBox.append(replyAllowed);
    TextInputElement twInp = new TextInputElement()
      ..style.width = HtmlLib.asPx(125)
      ..maxLength = 100
      ..placeholder = 'Trigger warning';
    postControlsBox.append(twInp);
    var imageButton = new ButtonElement() ..text = 'Upload Image' ..className = 'button';
    postControlsBox.append(imageButton);
    var postButton = new ButtonElement() ..text = 'Post (ctrl-Enter)' ..className = 'button';
    postControlsBox.append(postButton);

    //define showing or collapsing the post controls box based on whether the input has any text in it
    void expandCollapsePostControlsBox() {
      bool hasText = trimInputArea(replyInp).length > 0;
      if (hasText == isExpanded) return;
      isExpanded = hasText;
      if (isExpanded) {
        postControlsBox.style.display = 'block';
        replyInp.rows = 5;
      } else {
        postControlsBox.style.display = 'none';
        replyInp.rows = 1;
      }
    }

    //define hiding the post controls after a post is made
    setNonpostable() {
      replyInp.value = '';
      replyInp.remove();
      twInp.text = '';
      postControlsBox.remove();
      expandCollapsePostControlsBox();
    }

    //events on controls in postControlsBox
    imageButton.onClick.listen((e) async {
      ImageUploadDialog dialog = new ImageUploadDialog('P', 'Image will be reduced if it is very large.', _convId, replyInp.value);
      bool ok = await dialog.show();
      if (ok) {
        setNonpostable();
        Messages.timed('Posted. Refresh conversation to view post.');
      }
    });
    Future doPost0() async {
      await _savePost(trimInputArea(replyInp), trimInput(twInp));
      setNonpostable();
    }
    postButton.onClick.listen((e) => doPost0());
    replyInp.onKeyDown.listen((e) {
      if (e.ctrlKey && e.keyCode == KeyCode.ENTER) {
        doPost0();
        e.preventDefault();
      }
      new Timer(new Duration(milliseconds: 20), expandCollapsePostControlsBox);
    });
  }

  ///send new post to server, and then if successful, display post (as if it was loaded from server)
  Future _savePost(String text, String tw) async {
    String lastPostWDT = _lastPost != null ? _lastPost.createdAtWDT : null;
    APIResponseBase response = await RpcLib.command('ConvPostSave', new ConvPostSaveRequest()
      ..convId = _convId
      ..triggerWarning = tw
      ..ptext = text
      ..lastKnownWDT = lastPostWDT
    );
    if (response.isOK) {
      var item = new ConvGetPostItem() ..ptext = text
        ..collapseMode = 'Normal' ..collapsePosition = 300
        ..createdAtWDT = WLib.dateTimeToWire(WLib.utcNow());
      _appendOnePost(item, false);
    }
  }

  ///build main button bar (for the whole conv)
  void _buildMainButtonBar() {
    //important (like=I)
    if (_isJoined) {
      CheckboxInputElement imp = new CheckboxInputElement();
      SpanElement impWrap = new SpanElement() ..className = 'check' ..append(imp)
        ..appendText('Important');
      if (_conv.like == 'I') imp.checked = true;
      paneMenuBar.addElement(impWrap);
      imp.onChange.listen((e) async {
        ConvUserSaveRequest req = new ConvUserSaveRequest()
          ..convId = _convId
          ..like = (imp.checked ? 'I' : 'N');
        await RpcLib.convUserSave(req);
      });

    }

    //bookmarked
    if (_isJoined) {
      CheckboxInputElement bm = new CheckboxInputElement();
      SpanElement bmWrap = new SpanElement() ..className = 'check' ..append(bm)
        ..appendText('Bookmarked');
      if (_conv.bookmarked == 'Y') bm.checked = true;
      paneMenuBar.addElement(bmWrap);
      bm.onChange.listen((e) async {
        //update bookmarked items in my stuff
        PushQueueItem it = new PushQueueItem()
          ..kind = 'B' ..why = 'G'
          ..iid = _convId
          ..linkText = _conv.title
          ..linkPaneKey = paneKey.full;
        if (bm.checked) {
          PushQueueHandler.itemsReceived(false, [it], 'B');
        } else {
          PushQueueHandler.removeItem(it, '!');
        }

        //tell server
        ConvUserSaveRequest req = new ConvUserSaveRequest()
          ..convId = _convId
          ..bookmarked = (bm.checked ? 'Y' : 'N');
        await RpcLib.convUserSave(req);
      });
    }

    //join
    if (!_isJoined) {
      paneMenuBar.addButton('Join', (e) async {
        if (!Messages.checkLoggedIn()) return;
        ConvUserSaveResponse response = await RpcLib.convUserSave(new ConvUserSaveRequest()
          ..convId = _convId ..status = 'J');
        if (response.base.isOK) {
          recreatePane(); //reload whole pane now that we've joined
        }
        if (response.action == 'J') Messages.timed('Joined!');
        if (response.action == 'R') Messages.timed('A join request was sent to the project leadership for their approval.');
        if (response.action == 'X') Messages.timed('You are not allowed to join this private project.');
      });
    }

    //leave
    if (_isJoined) {
      paneMenuBar.addButton('Leave', (e) async {
        collapse();
        await RpcLib.convUserSave(new ConvUserSaveRequest()
          ..convId = _convId ..status = 'Q');
      });
    }

    //edit rules
    if (_isJoined && _isManager) {
      paneMenuBar.addButton('Edit Rules', (e) async {
        ConvDialog dlg = new ConvDialog(_convId, null, null);
        int editedId = await dlg.show();
        if (editedId == null) return;
        recreatePane();
      });
    }
  }

}
