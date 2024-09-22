{
  lib,
  writeText,
  fetchFromGitHub,
  nixosTests,
  python311,
}:
let
  py = python311.override {
    self = py;
    packageOverrides = final: prev: {
      django = prev.django_5;
    };
  };
in
py.pkgs.buildPythonApplication rec {
  pname = "healthchecks";
  version = "3.6";
  format = "other";

  src = fetchFromGitHub {
    owner = "healthchecks";
    repo = pname;
    rev = "5a19f9658ac557ce4ef4c3b8e0c33fc2dd20d239";
    sha256 = "sha256-aKt9L3ZgZ8HffcNNJaR+hAI38raWuLp2q/6+rvkl2pM=";
  };

  propagatedBuildInputs = with py.pkgs; [
    aiosmtpd
    apprise
    cronsim
    django
    django-compressor
    django-stubs-ext
    fido2
    minio
    oncalendar
    psycopg
    pycurl
    pydantic
    pyotp
    segno
    statsd
    whitenoise
  ];

  secrets = [
    "DB_PASSWORD"
    "DISCORD_CLIENT_SECRET"
    "EMAIL_HOST_PASSWORD"
    "LINENOTIFY_CLIENT_SECRET"
    "MATRIX_ACCESS_TOKEN"
    "PD_APP_ID"
    "PUSHBULLET_CLIENT_SECRET"
    "PUSHOVER_API_TOKEN"
    "S3_SECRET_KEY"
    "SECRET_KEY"
    "SLACK_CLIENT_SECRET"
    "TELEGRAM_TOKEN"
    "TRELLO_APP_KEY"
    "TWILIO_AUTH"
  ];

  localSettings = writeText "local_settings.py" ''
    import os

    STATIC_ROOT = os.getenv("STATIC_ROOT")
    SECURE_PROXY_SSL_HEADER = (lambda x: x if x is None else tuple(re.sub(r"[\(\)\"]","", x).replace(", ", ",").split(",")))(os.getenv("SECURE_PROXY_SSL_HEADER", None))

    ${lib.concatLines (
      map (secret: ''
        ${secret}_FILE = os.getenv("${secret}_FILE")
        if ${secret}_FILE:
            with open(${secret}_FILE, "r") as file:
                ${secret} = file.readline()
      '') secrets
    )}
  '';

  installPhase = ''
    mkdir -p $out/opt/healthchecks
    cp -r . $out/opt/healthchecks
    chmod +x $out/opt/healthchecks/manage.py
    cp ${localSettings} $out/opt/healthchecks/hc/local_settings.py
  '';

  passthru = {
    # PYTHONPATH of all dependencies used by the package
    pythonPath = py.pkgs.makePythonPath propagatedBuildInputs;

    tests = {
      inherit (nixosTests) healthchecks;
    };
  };

  meta = with lib; {
    homepage = "https://github.com/healthchecks/healthchecks";
    description = "Cron monitoring tool written in Python & Django";
    license = licenses.bsd3;
    maintainers = with maintainers; [ phaer ];
  };
}
