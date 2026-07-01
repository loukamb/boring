FROM archlinux:base-devel

RUN pacman -Syu --noconfirm --needed \
    ca-certificates \
    git \
    gcc \
    luajit \
    pkgconf \
    wlroots0.20 \
    wlr-protocols \
    wayland-protocols \
    libvips \
    xorg-xwayland \
    nodejs \
    pnpm \
    && pacman -Scc --noconfirm

ENV PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig
WORKDIR /workspace

CMD ["luajit", "tests/run.lua", "--suite", "all"]
