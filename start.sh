#root下运行
#apt update
#apt install binutils bison gawk gcc g++ m4 make patch python3 texinfo xz-utils
#apt install wget rsync
#ln -sf /bin/bash /bin/sh

MIRROR=akko.wutaohou.ru/cygauss/lfs-packages-12.4.tar
SRC_DIR=usr/src
CACHE_DIR=var/cache/pkg
LIB_DIR=var/lib/pkg
export MIRORR SRC_DIR CACHE_DIR LIB_DIR

export LFS=/mnt/lfs
umask 022

#确保无残留
[ ! -e /etc/bash.bashrc.NOUSE ] || mv -v /etc/bash.bashrc.NOUSE /etc/bash.bashrc
pkill -u lfs
rm -rf $LFS
userdel -r lfs
groupdel lfs

mkdir -pv $LFS
chmod 755 $LFS

mkdir -pv $LFS/$SRC_DIR
wget -O $LFS/$SRC_DIR/lfs-packages.tar "$MIRROR"
tar -xf $LFS/$SRC_DIR/lfs-packages.tar  --strip-components=1 -C $LFS/$SRC_DIR
chown -R root:root $LFS/$SRC_DIR

#软链接sbin,lib64到bin,lib,故修改原文
mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib}
ln -sv bin $LFS/usr/sbin
ln -sv usr/bin $LFS/sbin
ln -sv usr/bin $LFS/bin
ln -sv usr/lib $LFS/lib

case $(uname -m) in
  x86_64)
  ln -sv lib $LFS/usr/lib64
  ln -sv usr/lib $LFS/lib64
  ;;
esac
#tools太临时了就不改了
mkdir -pv $LFS/tools/bin

groupadd lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs
#简化
chown -R lfs:lfs $LFS

#结束后需返还
[ ! -e /etc/bash.bashrc ] || mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE

#因非交互shell做了调整

cat > /home/lfs/.bashrc << EOF
set +h
umask 022
LFS=$LFS
SRC_DIR=$SRC_DIR
CACHE_DIR=$CACHE_DIR
LIB_DIR=$LIB_DIR
export SRC_DIR CACHE_DIR LIB_DIR
EOF

cat >> /home/lfs/.bashrc << "EOF"
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
MAKEFLAGS=-j$(nproc)
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS
EOF

chown -R lfs:lfs /home/lfs

su - lfs << "SU"

env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash << "BASH"
source ~/.bashrc

cat > $LFS/tools/bin/ipkg << "EOF"
set -euo pipefail
mkdir -p $LFS/$LIB_DIR
rsync -aKni --existing $LFS/$CACHE_DIR/"$1"/ $LFS/ | awk '$1 != ".d..t......" { print; bad=1 } END { exit bad }'
rsync -aK $LFS/$CACHE_DIR/"$1"/ $LFS/
find $LFS/$CACHE_DIR/"$1" ! -type d -printf "$LFS/%P\n" > $LFS/$LIB_DIR/"$1"
EOF
chmod u+x $LFS/tools/bin/ipkg

cat > $LFS/tools/bin/upkg << "EOF"
set -euo pipefail
xargs -r rm -f -- < $LFS/$LIB_DIR/"$1"
rm -- $LFS/$LIB_DIR/"$1"
EOF
chmod u+x $LFS/tools/bin/upkg

pushd $LFS/$SRC_DIR

#package name
#tar -xf *z
#pushd */
#compile
#popd
#rm -rf */

#binutils-tools
tar -xf binutils*z
pushd binutils*/
mkdir -v build
cd       build
../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT   \
             --disable-nls       \
             --enable-gprofng=no \
             --disable-werror    \
             --enable-new-dtags  \
             --enable-default-hash-style=gnu
make
make install
popd
rm -rf binutils*/

#gcc-tools
tar -xf gcc*z
pushd gcc*/
tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc

#这里是指定该编译器生产的程序会默认查看lib而非lib64，如果去掉，不够标准
#且安装libstdc++时也会把库放进usr/lib64，无法按原文删除有害文件

case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/i386/t-linux64
 ;;
esac
mkdir -v build
cd       build
../configure                  \
    --target=$LFS_TGT         \
    --prefix=$LFS/tools       \
    --with-glibc-version=2.42 \
    --with-sysroot=$LFS       \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++
make
make install
cd ..
cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
  `dirname $($LFS_TGT-gcc -print-libgcc-file-name)`/include/limits.h
popd
rm -rf gcc*/

#linux-headers
tar -xf linux*z
pushd linux*/
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
#修改以建立fakeroot
mkdir -pv $LFS/$CACHE_DIR/linux-headers/usr
cp -r usr/include $LFS/$CACHE_DIR/linux-headers/usr
popd
rm -rf linux*/
ipkg linux-headers

#glibc-tmp
tar -xf glibc*z
pushd glibc*/
#从简不采用lsb和fhs的链接和补丁
mkdir -v build
cd       build
#从简不改变bin位置
../configure                             \
      --prefix=/usr                      \
      --host=$LFS_TGT                    \
      --build=$(../scripts/config.guess) \
      --disable-nscd                     \
      libc_cv_slibdir=/usr/lib           \
      --enable-kernel=5.4
make
make DESTDIR=$LFS/$CACHE_DIR/glibc-tmp install
# ldd 脚本无需更改
#测试需要在stow后运行，这里也去掉
popd
rm -rf glibc*/
ipkg glibc-tmp

#gcc-libstdc++-tmp
tar -xf gcc*z
pushd gcc*/
mkdir -v build
cd       build
../libstdc++-v3/configure      \
    --host=$LFS_TGT            \
    --build=$(../config.guess) \
    --prefix=/usr              \
    --disable-multilib         \
    --disable-nls              \
    --disable-libstdcxx-pch    \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/15.2.0
make
make DESTDIR=$LFS/$CACHE_DIR/gcc-libstdc++-tmp install
rm -v $LFS/$CACHE_DIR/gcc-libstdc++-tmp/usr/lib/lib{stdc++{,exp,fs},supc++}.la
popd
rm -rf gcc*/
ipkg gcc-libstdc++-tmp

#m4-tmp
tar -xf m4*z
pushd m4*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/m4-tmp install
popd
rm -rf m4*/
ipkg m4-tmp

#ncurses-tmp
tar -xf ncurses*z
pushd ncurses*/
mkdir build
pushd build
  ../configure --prefix=$LFS/tools AWK=gawk
  make -C include
  make -C progs tic
  install progs/tic $LFS/tools/bin
popd
./configure --prefix=/usr                \
            --host=$LFS_TGT              \
            --build=$(./config.guess)    \
            --mandir=/usr/share/man      \
            --with-manpage-format=normal \
            --with-shared                \
            --without-normal             \
            --with-cxx-shared            \
            --without-debug              \
            --without-ada                \
            --disable-stripping          \
            AWK=gawk
make
make DESTDIR=$LFS/$CACHE_DIR/ncurses-tmp install
ln -sv libncursesw.so $LFS/$CACHE_DIR/ncurses-tmp/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i $LFS/$CACHE_DIR/ncurses-tmp/usr/include/curses.h
popd
rm -rf ncurses*/
ipkg ncurses-tmp

#bash-tmp
tar -xf bash*z
pushd bash*/
./configure --prefix=/usr                      \
            --build=$(sh support/config.guess) \
            --host=$LFS_TGT                    \
            --without-bash-malloc
make
make DESTDIR=$LFS/$CACHE_DIR/bash-tmp install
ln -sv bash $LFS/$CACHE_DIR/bash-tmp/usr/bin/sh
popd
rm -rf bash*/
ipkg bash-tmp

#coreutils-tmp
tar -xf coreutils*z
pushd coreutils*/
./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --enable-install-program=hostname \
            --enable-no-install-program=kill,uptime
make
make DESTDIR=$LFS/$CACHE_DIR/coreutils-tmp install
#无需移动手册
popd
rm -rf coreutils*/
ipkg coreutils-tmp

#diffutils-tmp
tar -xf diffutils*z
pushd diffutils*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            gl_cv_func_strcasecmp_works=y \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/diffutils-tmp install
popd
rm -rf diffutils*/
ipkg diffutils-tmp

#file-tmp
tar -xf file*z
pushd file*/
mkdir build
pushd build
  ../configure --disable-bzlib      \
               --disable-libseccomp \
               --disable-xzlib      \
               --disable-zlib
  make
popd
./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)
make FILE_COMPILE=$(pwd)/build/src/file
make DESTDIR=$LFS/$CACHE_DIR/file-tmp install
rm -v $LFS/$CACHE_DIR/file-tmp/usr/lib/libmagic.la
popd
rm -rf file*/
ipkg file-tmp

#findutils-tmp
tar -xf findutils*z
pushd */
#放弃fhs，从简
./configure --prefix=/usr                   \
            --host=$LFS_TGT                 \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/findutils-tmp install
popd
rm -rf findutils*/
ipkg findutils-tmp

#gawk-tmp
tar -xf gawk*z
pushd gawk*/
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/gawk-tmp install
popd
rm -rf gawk*/
ipkg gawk-tmp

#grep-tmp
tar -xf grep*z
pushd grep*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/grep-tmp install
popd
rm -rf grep*/
ipkg grep-tmp

#gzip-tmp
tar -xf gzip*z
pushd gzip*/
./configure --prefix=/usr --host=$LFS_TGT
make
make DESTDIR=$LFS/$CACHE_DIR/gzip-tmp install
popd
rm -rf gzip*/
ipkg gzip-tmp

#make-tmp
tar -xf make*z
pushd make*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/make-tmp install
popd
rm -rf make*/
ipkg make-tmp

#patch-tmp
tar -xf patch*z
pushd patch*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/patch-tmp install
popd
rm -rf patch*/
ipkg patch-tmp

#sed-tmp
tar -xf sed*z
pushd sed*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/sed-tmp install
popd
rm -rf sed*/
ipkg sed-tmp

#tar-tmp
tar -xf tar*z
pushd tar*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/$CACHE_DIR/tar-tmp install
popd
rm -rf tar*/
ipkg tar-tmp

#xz-tmp
tar -xf xz*z
pushd xz*/
#省略将/usr/share/doc/xz加上-5.8.1
./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --disable-static
make
make DESTDIR=$LFS/$CACHE_DIR/xz-tmp install
rm -v $LFS/$CACHE_DIR/xz-tmp/usr/lib/liblzma.la
popd
rm -rf xz*/
ipkg xz-tmp

#binutils-tmp
tar -xf binutils*z
pushd binutils*/
sed '6031s/$add_dir//' -i ltmain.sh
mkdir -v build
cd       build
../configure                   \
    --prefix=/usr              \
    --build=$(../config.guess) \
    --host=$LFS_TGT            \
    --disable-nls              \
    --enable-shared            \
    --enable-gprofng=no        \
    --disable-werror           \
    --enable-64-bit-bfd        \
    --enable-new-dtags         \
    --enable-default-hash-style=gnu
make
make DESTDIR=$LFS/$CACHE_DIR/binutils-tmp install
rm -v $LFS/$CACHE_DIR/binutils-tmp/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
popd
rm -rf binutils*/
ipkg binutils-tmp

#gcc-tmp
tar -xf gcc*z
pushd gcc*/
tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc
#不可删
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/i386/t-linux64
  ;;
esac
sed '/thread_header =/s/@.*@/gthr-posix.h/' \
    -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
mkdir -v build
cd       build
../configure                   \
    --build=$(../config.guess) \
    --host=$LFS_TGT            \
    --target=$LFS_TGT          \
    --prefix=/usr              \
    --with-build-sysroot=$LFS  \
    --enable-default-pie       \
    --enable-default-ssp       \
    --disable-nls              \
    --disable-multilib         \
    --disable-libatomic        \
    --disable-libgomp          \
    --disable-libquadmath      \
    --disable-libsanitizer     \
    --disable-libssp           \
    --disable-libvtv           \
    --enable-languages=c,c++   \
    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc
make
make DESTDIR=$LFS/$CACHE_DIR/gcc-tmp install
ln -sv gcc $LFS/$CACHE_DIR/gcc-tmp/usr/bin/cc
popd
rm -rf gcc*/
upkg  gcc-libstdc++-tmp
ipkg gcc-tmp

#暂时结束安装
popd
BASH
SU
[ ! -e /etc/bash.bashrc.NOUSE ] || mv -v /etc/bash.bashrc.NOUSE /etc/bash.bashrc
chown -R root:root $LFS