#root下确认依赖是否齐全,额外需要wget
#不是开头改LFS就能随意换文件夹
export LFS=/mnt/lfs
umask 022

#通过支持重用，减少中断损失，来提高健壮性
rm -rf $LFS
ps -u lfs -o pid= | xargs kill
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
pushd $LFS/sources
  md5sum -c md5sums
popd

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

#进入lfs，这里要EOF化
su - lfs << "SU"

cat > ~/.bash_profile << "EOF"
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

cat > ~/.bashrc << "EOF"
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
EOF

cat >> ~/.bashrc << "EOF"
export MAKEFLAGS=-j$(nproc)
EOF
SU

#source是不开新shell的，exec相反，由于一些复杂问题，这里修改得虽然蠢，但是对再修改的兼容性高
su - lfs << "SU"
source ~/.bashrc
#加上括号来只输出错误
(
#参考如下，因用处太小不写脚本
#tar -xf *z
#pushd */
#compile
#popd
#rm -rf */

pushd $LFS/sources

#binutils

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


#gcc

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

#测试去掉了
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
popd
) > /dev/null
SU
