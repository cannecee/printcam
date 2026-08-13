# PrintCam — Fly.io için MediaMTX imajı.
#
# Resmi mediamtx imajı `scratch` tabanlıdır (shell/paket yöneticisi yok),
# binary /mediamtx yolunda ve argümansız çalışır — bu yüzden varsayılan
# olarak /mediamtx.yml config dosyasını arar. Yaptığımız tek şey, kendi
# config'imizi tam olarak o yola koymak.
FROM bluenviron/mediamtx:1

COPY mediamtx.fly.yml /mediamtx.yml
