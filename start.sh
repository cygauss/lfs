#导向/dev/null 来只输出错误
#root下确认依赖是否齐全,额外需要wget，多要求一个bc，参考clfs
export LFS=/mnt/lfs
umask 022

#通过支持重用，减少中断损失，来提高健壮性
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
#系统可能没wget。且如果分开下会被gnu的服务器气晕，注意调整镜像，去掉顶目录
wget https://mirrors.ustc.edu.cn/lfs/lfs-packages/lfs-packages-12.4.tar --directory-prefix=$LFS/sources
tar -xf $LFS/sources/lfs-packages-12.4.tar  --strip-components=1 -C $LFS/sources

#测试
#pushd $LFS/sources
#  md5sum -c md5sums
#popd

#考虑到lib64的问题，很多发行版保留了/lib64但是弃用了/usr/lib64，同时sbin也没有必要了，我们这里统一软连接，故这里修改了原文
mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib}
ln -sv bin $LFS/usr/sbin
for i in bin lib sbin; do
  ln -sv usr/$i $LFS/$i
done
case $(uname -m) in
  x86_64)
  ln -sv lib $LFS/usr/lib64
  ln -sv usr/lib64 $LFS/lib64
  ;;
esac
mkdir -pv $LFS/tools

groupadd lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs
#因lib64,sbin调整，删除了不需要的部分。软连接不需要考虑权限
chown -v lfs $LFS/{usr{,/bin,/lib},var,etc,tools}

#这里移除，要在开头和最后确认换回来。
[ ! -e /etc/bash.bashrc ] || mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE

#进入lfs，这里要非交互化，考虑到$LFS,exec,env,source,交互，登录等各种问题，这里做了比较大的调整
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
LFS_TGT=$(uname -m)-lfs-linux-gnu
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

#参考如下，因用处太小不写脚本
#tar -xf *z
#pushd */
#compile
#popd
#rm -rf */

pushd $LFS/sources


#binutils第一遍
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


#gcc第一遍
tar -xf gcc*z
pushd gcc*/
tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc
mkdir -v build
cd       build
#因lib64调整，删除了不需要的部分
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


#linux header
tar -xf linux*z
pushd linux*/
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
popd
rm -rf linux*/


#glibc
tar -xf glibc*z
pushd glibc*/
#这里因合并lib64修改
case $(uname -m) in
    i?86)   ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3
    ;;
    x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
    ;;
esac
#这里从简，没有应用兼容fhs的补丁
mkdir -v build
cd       build
#无需指定工具到sbin

../configure                             \
      --prefix=/usr                      \
      --host=$LFS_TGT                    \
      --build=$(../scripts/config.guess) \
      --disable-nscd                     \
      libc_cv_slibdir=/usr/lib           \
      --enable-kernel=5.4
make
make DESTDIR=$LFS install
sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd

#测试
#echo 'int main(){}' | $LFS_TGT-gcc -x c - -v -Wl,--verbose &> dummy.log
#readelf -l a.out | grep ': /lib'
#grep -E -o "$LFS/lib.*/S?crt[1in].*succeeded" dummy.log
#grep -B3 "^ $LFS/usr/include" dummy.log
#grep 'SEARCH.*/usr/lib' dummy.log |sed 's|; |\n|g'
#grep "/lib.*/libc.so.6 " dummy.log
#grep found dummy.log
#rm -v a.out dummy.log

popd
rm -rf glibc*/


#Libstdc++
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
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la
popd
rm -rf gcc*/

#待续
#m4
tar -xf m4*z
pushd m4*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf m4*/

#ncurses
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
make DESTDIR=$LFS install
ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i $LFS/usr/include/curses.h
popd
rm -rf ncurses*/

#bash
tar -xf bash*z
pushd bash*/
./configure --prefix=/usr                      \
            --build=$(sh support/config.guess) \
            --host=$LFS_TGT                    \
            --without-bash-malloc
make
make DESTDIR=$LFS install
ln -sv bash $LFS/bin/sh
popd
rm -rf bash*/

#coreutils
tar -xf coreutils*z
pushd coreutils*/
./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --enable-install-program=hostname \
            --enable-no-install-program=kill,uptime
make
make DESTDIR=$LFS install
mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
mkdir -pv $LFS/usr/share/man/man8
mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8
popd
rm -rf coreutils*/

#diffutils
tar -xf diffutils*z
pushd diffutils*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            gl_cv_func_strcasecmp_works=y \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf diffutils*/

#file
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
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/libmagic.la
popd
rm -rf file*/

#findutils
tar -xf findutils*z
pushd */
./configure --prefix=/usr                   \
            --localstatedir=/var/lib/locate \
            --host=$LFS_TGT                 \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf findutils*/

#gawk
tar -xf gawk*z
pushd gawk*/
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf gawk*/

#grep
tar -xf grep*z
pushd grep*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf grep*/

#gzip
tar -xf gzip*z
pushd gzip*/
./configure --prefix=/usr --host=$LFS_TGT
make
make DESTDIR=$LFS install
popd
rm -rf gzip*/

#make
tar -xf make*z
pushd make*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf make*/

#patch
tar -xf patch*z
pushd patch*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf patch*/

#sed
tar -xf sed*z
pushd sed*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf sed*/

#tar
tar -xf tar*z
pushd tar*/
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
popd
rm -rf tar*/

#xz
tar -xf xz*z
pushd xz*/
./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --disable-static                  \
            --docdir=/usr/share/doc/xz-5.8.1
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/liblzma.la
popd
rm -rf xz*/

#binutils第二遍
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
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
popd
rm -rf binutils*/

#gcc第二遍
tar -xf gcc*z
pushd gcc*/
tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc
#同第一次，删除无用部分
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
make DESTDIR=$LFS install
ln -sv gcc $LFS/usr/bin/cc
popd
rm -rf gcc*/

#util-linux部分程序
tar -xf util-linux*z
pushd util-linux*/
./configure --build=$(config/config.guess) --host=$LFS_TGT --disable-shared
make agetty mount setsid
install -vm755 agetty       $LFS/usr/sbin
install -vm755 mount setsid $LFS/usr/bin
popd
rm -rf util-linux*/

#暂时结束安装
popd
SU
[ ! -e /etc/bash.bashrc.NOUSE ] || mv -v /etc/bash.bashrc.NOUSE /etc/bash.bashrc

mkdir -pv /mnt/lfs-target
cp -av $LFS/* /mnt/lfs-target
chown -R root:root /mnt/lfs-target
install -v -dm755 /mnt/lfs-target/dev

