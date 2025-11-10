#root下确认依赖是否齐全,额外需要wget。clfs因内核需要bc.加上stow来作为包管理
#apt update
#apt install binutils bison gawk gcc g++ m4 make patch python3 texinfo xz-utils wget stow
#ln -sf /bin/bash /bin/sh
export LFS=/mnt/lfs
umask 022

#确保无残留
[ ! -e /etc/bash.bashrc.NOUSE ] || mv -v /etc/bash.bashrc.NOUSE /etc/bash.bashrc
pkill -u lfs
rm -rf $LFS
userdel -r lfs
groupdel lfs

mkdir -pv $LFS
chown root:root $LFS
chmod 755 $LFS

mkdir -v $LFS/sources
chmod -v a+wt $LFS/sources
wget https://mirrors.ustc.edu.cn/lfs/lfs-packages/lfs-packages-12.4.tar --directory-prefix=$LFS/sources
tar -xf $LFS/sources/lfs-packages-12.4.tar  --strip-components=1 -C $LFS/sources

#测试
#pushd $LFS/sources
#  md5sum -c md5sums
#popd

#软链接sbin,lib64到bin,lib，增加store,故修改原文
mkdir -pv $LFS/{etc,var,store} $LFS/usr/{bin,lib}
ln -sv bin $LFS/usr/sbin
for i in bin lib sbin; do
  ln -sv usr/$i $LFS/$i
done
mkdir -pv $LFS/tools

groupadd lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs
#软链接不需要考虑权限
chown -v lfs $LFS/{usr{,/bin,/lib},var,etc,tools,store}

#结束后需返还
[ ! -e /etc/bash.bashrc ] || mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE

#因非交互shell,考虑到$LFS,bash,source等，这里做了调整
su - lfs << SU
cat > ~/.bashrc << "EOF"
set +h
umask 022
LFS=$LFS
EOF
SU

su - lfs << "SU"
cat > ~/.bash_profile << "EOF"
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

cat >> ~/.bashrc << "EOF"
LC_ALL=POSIX
LFS_TGT=s390x-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
MAKEFLAGS=-j$(nproc)
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS
EOF
SU

su - lfs << "SU"
source ~/.bashrc

#package name
#tar -xf *z
#pushd */
#compile
#popd
#rm -rf */

pushd $LFS/sources

#前两个交叉工具如果stow化得不偿失
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

#这里是指定该编译器生产的程序会默认查看lib/，去掉会让libstdc把库放进usr/lib64，于是删除有害文件的那一步就会失败
#虽然已经软链接了，但方便后续程序的stow，KISS上看，这里不能去掉
case $(uname -m) in
  s390x)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/s390/t-linux64
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
#修改以stow
mkdir -p $LFS/store/linux-headers/usr
cp -rv usr/include $LFS/store/linux-headers/usr
popd
rm -rf linux*/
stow -d $LFS/store -t $LFS/ -S linux-headers

#glibc-tmp
tar -xf glibc*z
pushd glibc*/
#从简不采用lsb和fhs的链接和补丁
mkdir -v build
cd       build
#因/usr/sbin修改，使得stow正常工作
#加上--sbindir=EPREFIX/bin也改变不了两个程序的位置usr/sbin，要在这里加
cat > configparms << "EOF"
rootsbindir=/usr/bin
sbindir=/usr/bin
EOF
../configure                             \
      --prefix=/usr                      \
      --host=$LFS_TGT                    \
      --build=$(../scripts/config.guess) \
      --disable-nscd                     \
      libc_cv_slibdir=/usr/lib           \
      --enable-kernel=5.4
make
make DESTDIR=$LFS/store/glibc-tmp install
# ldd 脚本无需更改
#测试需要在stow后运行，这里也去掉
popd
rm -rf glibc*/
stow -d $LFS/store -t $LFS/ -S glibc-tmp

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
make DESTDIR=$LFS/store/gcc-libstdc++-tmp install
rm -v $LFS/store/gcc-libstdc++-tmp/usr/lib/lib{stdc++{,exp,fs},supc++}.la
popd
rm -rf gcc*/
stow -d $LFS/store -t $LFS/ -S gcc-libstdc++-tmp

#m4-tmp
tar -xf m4*z
pushd m4*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/store/m4-tmp install
popd
rm -rf m4*/
stow -d $LFS/store -t $LFS/ -S m4-tmp

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
make DESTDIR=$LFS/store/ncurses-tmp install
ln -sv libncursesw.so $LFS/store/ncurses-tmp/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i $LFS/store/ncurses-tmp/usr/include/curses.h
popd
rm -rf ncurses*/
stow -d $LFS/store -t $LFS/ -S ncurses-tmp

#bash-tmp
tar -xf bash*z
pushd bash*/
./configure --prefix=/usr                      \
            --build=$(sh support/config.guess) \
            --host=$LFS_TGT                    \
            --without-bash-malloc
make
make DESTDIR=$LFS/store/bash-tmp install
#这里因为是bash-tmp目录里没bin，要添加usr
ln -sv bash $LFS/store/bash-tmp/usr/bin/sh
popd
rm -rf bash*/
stow -d $LFS/store -t $LFS/ -S bash-tmp

#coreutils-tmp
tar -xf coreutils*z
pushd coreutils*/
./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --enable-install-program=hostname \
            --enable-no-install-program=kill,uptime
make
make DESTDIR=$LFS/store/coreutils-tmp install
mkdir -pv $LFS/store/coreutils-tmp/usr/share/man/man8
mv -v $LFS/store/coreutils-tmp/usr/share/man/man1/chroot.1 $LFS/store/coreutils-tmp/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/'                    $LFS/store/coreutils-tmp/usr/share/man/man8/chroot.8
popd
rm -rf coreutils*/
stow -d $LFS/store -t $LFS/ -S coreutils-tmp

#diffutils-tmp
tar -xf diffutils*z
pushd diffutils*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            gl_cv_func_strcasecmp_works=y \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS/store/diffutils-tmp install
popd
rm -rf diffutils*/
stow -d $LFS/store -t $LFS/ -S diffutils-tmp

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
make DESTDIR=$LFS/store/file-tmp install
rm -v $LFS/store/file-tmp/usr/lib/libmagic.la
popd
rm -rf file*/
stow -d $LFS/store -t $LFS/ -S file-tmp

#findutils-tmp
tar -xf findutils*z
pushd */
#放弃fhs，从简
./configure --prefix=/usr                   \
            --host=$LFS_TGT                 \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/store/findutils-tmp install
popd
rm -rf findutils*/
stow -d $LFS/store -t $LFS/ -S findutils-tmp

#gawk-tmp
tar -xf gawk*z
pushd gawk*/
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/store/gawk-tmp install
popd
rm -rf gawk*/
stow -d $LFS/store -t $LFS/ -S gawk-tmp

#grep-tmp
tar -xf grep*z
pushd grep*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS/store/grep-tmp install
popd
rm -rf grep*/
stow -d $LFS/store -t $LFS/ -S grep-tmp

#gzip-tmp
tar -xf gzip*z
pushd gzip*/
./configure --prefix=/usr --host=$LFS_TGT
make
make DESTDIR=$LFS/store/gzip-tmp install
popd
rm -rf gzip*/
stow -d $LFS/store -t $LFS/ -S gzip-tmp

#make-tmp
tar -xf make*z
pushd make*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/store/make-tmp install
popd
rm -rf make*/
stow -d $LFS/store -t $LFS/ -S make-tmp

#patch-tmp
tar -xf patch*z
pushd patch*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/store/patch-tmp install
popd
rm -rf patch*/
stow -d $LFS/store -t $LFS/ -S patch-tmp

#sed-tmp
tar -xf sed*z
pushd sed*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS/store/sed-tmp install
popd
rm -rf sed*/
stow -d $LFS/store -t $LFS/ -S sed-tmp

#tar-tmp
tar -xf tar*z
pushd tar*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS/store/tar-tmp install
popd
rm -rf tar*/
stow -d $LFS/store -t $LFS/ -S tar-tmp

#xz-tmp
tar -xf xz*z
pushd xz*/
#省略将/usr/share/doc/xz加上-5.8.1
./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --disable-static
make
make DESTDIR=$LFS/store/tar-tmp install
rm -v $LFS/store/tar-tmp/usr/lib/liblzma.la
popd
rm -rf xz*/
stow -d $LFS/store -t $LFS/ -S tar-tmp

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
make DESTDIR=$LFS/store/binutils-tmp install
rm -v $LFS/store/binutils-tmp/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
popd
rm -rf binutils*/
stow -d $LFS/store -t $LFS/ -S binutils-tmp

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
  s390x)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/s390/t-linux64
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
make DESTDIR=$LFS/store/gcc-tmp install
ln -sv gcc $LFS/store/gcc-tmp/usr/bin/cc
popd
rm -rf gcc*/
stow -d $LFS/store -t $LFS/ -S gcc-tmp -D gcc-libstdc++-tmp

#暂时结束安装
popd
SU
[ ! -e /etc/bash.bashrc.NOUSE ] || mv -v /etc/bash.bashrc.NOUSE /etc/bash.bashrc

