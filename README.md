## Hyprland for Void Linux

This repository contains template files and binaries for building or installing [Hyprland](https://github.com/hyprwm/Hyprland) on Void Linux.

### Installation

The easiest way to install Hyprland on Void Linux is using the [repository](https://github.com/sofijacom/hyprland-void/tree/repository-x86_64-glibc) which consists of binaries built automatically using GitHub Actions whenever a new commit is pushed to this repository.

You can add this repository to xbps's repositories by creating a file such as `/etc/xbps.d/hyprland-void.conf` with the following text:

```
repository=https://raw.githubusercontent.com/sofijacom/hyprland-void/repository-x86_64-glibc
```

You should then be able to install hyprland like you would any other program:

```
sudo xbps-install -S hyprland
```

You can also search through all hypr related packages as you would any other (you will need to accept the repository's fingerprint first with `xbps-install -S`)

```
xbps-query -Rs hypr
```

Currently this repository provides binary packages for:

- x86_64-glibc
- x86_64-musl
- ~~aarch64-glibc~~
- ~~aarch64-musl~~

Change the end of the url at `/etc/xbps.d/hyprland-void.conf` as appropriate with the above options.

### Running

In order to run Hyprland you will need to install some additional packages which will depend on your setup, for example a [session and seat manager](https://docs.voidlinux.org/config/session-management.html) and [graphics drivers](https://docs.voidlinux.org/config/graphical-session/graphics-drivers/index.html). You may also have to add the user to the `_seatd` group. If you use an Nvidia GPU refer to the [Hyprland Wiki](https://wiki.hyprland.org/Nvidia), but keep in mind that Hyprland does not officially support Nvidia.

### Extra
There are packages in this repository which may be of interest for:

- hypridle
- hyprlock
- hyprpaper
- xdg-desktop-portal-hyprland

### Manually Building

You may want to build these templates manually, for example if you have a specific configuration requirement that needs to be set at build time. Void-packages may sometimes have specific packages which are out of date from time to time that need to be updated beforehand in order to update Hyprland, which is why this repository is not simply forked off it. We need to copy the modifications from this repository on top of a fresh void-packages clone in order to build manually.

1) You may want to start by making a directory where you can keep the relevant repositories

```
mkdir ~/repos
cd ~/repos
```

2) Set up a [void-packages](https://github.com/void-linux/void-packages) clone for building templates files

```
git clone https://github.com/void-linux/void-packages
cd void-packages
./xbps-src binary-bootstrap
cd ..
```

3) Clone this repository:

```
git clone https://github.com/Makrennel/hyprland-void.git
cd hyprland-void
```

4) Append shared libraries to the end of your void-packages shared libraries

```
cat common/shlibs >> ../void-packages/common/shlibs
```

5) Copy srcpkgs to your void-packages srcpkgs directory

```
cp -r --remove-destination srcpkgs/* ../void-packages/srcpkgs
```

6) Build and install packages

```
cd ../void-packages
./xbps-src pkg hyprland
sudo xbps-install -R hostdir/binpkgs hyprland
```

