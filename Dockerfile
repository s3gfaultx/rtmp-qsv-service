ARG DEBIAN_VERSION=bullseye-slim 

FROM debian:${DEBIAN_VERSION} as builder

ARG  NGINX_VERSION=1.23.3
ARG  NGINX_RTMP_MODULE_VERSION=1.2.2
ARG  FFMPEG_VERSION=5.1
ARG  MEDIASDK_VERSION=22.5.4
ARG  LIBVA_VERSION=2.16.0

# Install dependencies
RUN apt-get update && \
	apt-get install -y \
		wget build-essential ca-certificates \
		openssl libssl-dev yasm cmake \
		pkg-config libdrm-dev \
		libpcre3-dev librtmp-dev libtheora-dev \
		libvorbis-dev libvpx-dev libfreetype6-dev \
		libmp3lame-dev libx264-dev libx265-dev && \
    rm -rf /var/lib/apt/lists/*

# Download nginx source
RUN mkdir -p /tmp/build && \
	cd /tmp/build && \
	wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
	tar -zxf nginx-${NGINX_VERSION}.tar.gz && \
	rm nginx-${NGINX_VERSION}.tar.gz

# Download rtmp-module source
RUN cd /tmp/build && \
    wget https://github.com/arut/nginx-rtmp-module/archive/v${NGINX_RTMP_MODULE_VERSION}.tar.gz && \
    tar -zxf v${NGINX_RTMP_MODULE_VERSION}.tar.gz && \
	rm v${NGINX_RTMP_MODULE_VERSION}.tar.gz

# Build nginx with nginx-rtmp module
RUN cd /tmp/build/nginx-${NGINX_VERSION} && \
    ./configure \
        --sbin-path=/usr/local/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \		
        --pid-path=/var/run/nginx/nginx.pid \
        --lock-path=/var/lock/nginx.lock \
        --http-client-body-temp-path=/tmp/nginx-client-body \
        --with-http_ssl_module \
        --with-threads \
        --add-module=/tmp/build/nginx-rtmp-module-${NGINX_RTMP_MODULE_VERSION} && \
    make -j $(getconf _NPROCESSORS_ONLN) && \
    make install

# Download libVA source
RUN cd /tmp/build && \
  wget https://github.com/intel/libva/releases/download/${LIBVA_VERSION}/libva-${LIBVA_VERSION}.tar.bz2 && \
  tar -jxf libva-${LIBVA_VERSION}.tar.bz2 && \
  rm libva-${LIBVA_VERSION}.tar.bz2

# Build libVA
RUN cd /tmp/build/libva-${LIBVA_VERSION} && \
  ./configure && \
  make -j4 && \
  make install && \
  ldconfig

# Download MediaSDK source
RUN cd /tmp/build && \
  wget https://github.com/Intel-Media-SDK/MediaSDK/archive/refs/tags/intel-mediasdk-${MEDIASDK_VERSION}.tar.gz && \
  tar -zxf intel-mediasdk-${MEDIASDK_VERSION}.tar.gz && \
  rm intel-mediasdk-${MEDIASDK_VERSION}.tar.gz

# Build MediaSDK
RUN cd /tmp/build/MediaSDK-intel-mediasdk-${MEDIASDK_VERSION} && \
  mkdir build && \
  cd build && \
  cmake .. && \
  make -j8 && \
  make install

RUN echo "/opt/intel/mediasdk/lib" > /etc/ld.so.conf.d/mediasdk.conf && \
  ldconfig

# Download ffmpeg source
RUN cd /tmp/build && \
  wget http://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz && \
  tar -zxf ffmpeg-${FFMPEG_VERSION}.tar.gz && \
  rm ffmpeg-${FFMPEG_VERSION}.tar.gz
  
# Build ffmpeg
RUN cd /tmp/build/ffmpeg-${FFMPEG_VERSION} && \
  export LIBVA_DRIVER_NAME=iHD && \
  export MFX_HOME=/opt/intel/mediasdk && \
  export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/opt/intel/mediasdk/lib/pkgconfig && \
  ./configure \
	  --enable-gpl \
	  --enable-version3 \
	  --enable-nonfree \
	  --enable-small \
	  --enable-libx264 \
	  --enable-libx265 \
	  --enable-libvpx \
	  --enable-libtheora \
	  --enable-libvorbis \
	  --enable-librtmp \
	  --enable-libmfx \
	  --enable-postproc \
	  --enable-swresample \ 
	  --enable-libfreetype \
	  --enable-libmp3lame \
	  --disable-debug \
	  --disable-doc \
	  --disable-ffplay \
	  --extra-libs="-lpthread -lm" && \
	make -j $(getconf _NPROCESSORS_ONLN) && \
	make install

# Copy stats.xsl file to nginx html directory and cleaning build files
RUN cp /tmp/build/nginx-rtmp-module-${NGINX_RTMP_MODULE_VERSION}/stat.xsl /usr/local/nginx/html/stat.xsl && \
	rm -rf /tmp/build

##### Building the final image #####
FROM debian:${DEBIAN_VERSION}

# Install dependencies
RUN apt-get update && \
	apt-get install -y \
		ca-certificates openssl libpcre3-dev \
		librtmp1 libtheora0 libvorbis-dev libmp3lame0 \
		libvpx6 libx264-dev libx265-dev libdrm-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy files from build stage to final stage	
COPY --from=builder /usr/local /usr/local
COPY --from=builder /opt/intel/mediasdk /opt/intel/mediasdk
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /var/log/nginx /var/log/nginx
COPY --from=builder /var/lock /var/lock
COPY --from=builder /var/run/nginx /var/run/nginx

RUN echo "/opt/intel/mediasdk/lib" > /etc/ld.so.conf.d/mediasdk.conf && \
  ldconfig

# Forward logs to Docker
RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Copy  nginx config file to container
COPY conf/nginx.conf /etc/nginx/nginx.conf

# Copy  html players to container
COPY players /usr/local/nginx/html/players

EXPOSE 1935
EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
