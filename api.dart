import 'dart:io' as io;
import 'package:angel_framework/angel_framework.dart';
import 'package:angel_framework/http.dart';
import 'package:angel_static/angel_static.dart';
import 'package:angel_cors/angel_cors.dart';
import 'package:file/local.dart' as file;
import 'package:angel_container/mirrors.dart';
import 'server/api_globals.dart';
import 'server/pulse.dart';
import 'server/servant_controller.dart';
import 'server/config_loader.dart';
import 'server/linkback.dart';
import 'server/date_lib.dart';
import 'server/database.dart';
import 'server/image_lib.dart';

//app entry point
main() async {
  print("starting autzone API listener");

  //set up globals and other initializers
  ApiGlobals.configLoader.init(true);
  bool isDev = ApiGlobals.configLoader.isDev;
  await DateLib.init();
  ImageLib.init(ApiGlobals.configSettings);

  //write alive file (do early so supervisor doesn't try to run api twice)
  Pulse pulse = new Pulse();
  pulse.writeAliveFile(true);

  //init database (potentially slower)
  await Database.init();
  await Database.loadGlobals();

  //set up Angel
  var angelApp = new Angel(reflector: MirrorsReflector());
  AngelHttp angelHttp;
  int port;
  if (isDev) {
    angelHttp = AngelHttp(angelApp);
    print('developer mode, nonsecure');
    port = 8081;
  } else {
    final context = new io.SecurityContext();
    context.useCertificateChain('/etc/letsencrypt/live/www.autistic.zone/fullchain.pem');
    context.usePrivateKey('/etc/letsencrypt/live/www.autistic.zone/privkey.pem');
    String host = ApiGlobals.configSettings.domain;
    print('production mode - port 443 on host ${host}');
    angelHttp = AngelHttp.fromSecurityContext(angelApp, context);
    port = 443;
  }

  //add routes for diagnostics/dev-mode
  if (isDev) angelApp.fallback(cors());
  angelApp.get("/hello", (req, res) => "Hello, world!");

  //add routes for servant (the main api)
  await angelApp.configure(new ServantController().configureServer);

  //add routes for static files
  final fs = const file.LocalFileSystem();
  final publicDir = fs.directory(ConfigLoader.rootPath() + '/public_html');
  final vDirRoot = CachingVirtualDirectory(angelApp, fs, source: publicDir);
  angelApp.get('images/*', vDirRoot.handleRequest);
  angelApp.get('js/*', vDirRoot.handleRequest);
  angelApp.get('styles/*', vDirRoot.handleRequest);
  angelApp.get('/', vDirRoot.handleRequest);
  angelApp.get('/main.dart.js', vDirRoot.handleRequest);

  //attach the link-back style requests to the router (these include any
  // methods not served in the RPC style, such as links sent by email)
  angelApp.get('/linkback/ValidateEmail', (req, resp) => Linkback.validateEmail(req, resp));

  //start listener
  final server = await angelHttp.startServer('0.0.0.0', port);
  print("Angel server listening at ${angelHttp.uri}");

  //start redirector on port 80 to force main page to be secure
  io.HttpServer nonSucureRedirectServer;
  if (!isDev) {
    final angelNonsecureRedirector = Angel();
    angelNonsecureRedirector.get('/.well-known/acme-challenge/*', vDirRoot.handleRequest); //this is for certbot
    //http://localhost:8087/.well-known/acme-challenge/index.html
    angelNonsecureRedirector.fallback((req, resp) {
      if (req.path.contains('.well-known')) return; //this prevents the certbot call from being redirected
      resp.redirect(ApiGlobals.configSettings.homeUrl);
    });
    final nonsecureHttp = AngelHttp(angelNonsecureRedirector);
    nonSucureRedirectServer = await nonsecureHttp.startServer('0.0.0.0', 80);
  }

  //start 30s pulse tasks and register app-ending code
  pulse.init(() async {
    await server.close(force: true);
    await nonSucureRedirectServer.close(force: true);
    ApiGlobals.configLoader.stopWatching();
    await Database.dispose();

    //in testing, this method does end, but the dart process takes a couple more
    // minutes to actually end.
    //For now, really really force it
    io.sleep(new Duration(seconds: 5));
    io.exit(0);
  });
  pulse.start();
}
