#define _GNU_SOURCE
#include <pwd.h>
#include <unistd.h>
#include <string.h>

/*
 * fakepw.so — 让非 root 的 dropbear 能用任意用户名登录。
 *
 * dropbear 在非 root 模式下会校验 getpwnam(username)->pw_uid == geteuid()；
 * 平台强制容器以随机 uid（988/999/...）运行，镜像 /etc/passwd 无法在只读
 * 根文件系统上运行时修改，硬编码某个 uid 会在换节点后失效。
 *
 * 这个库劫持 getpwnam/getpwuid，永远返回一个 uid = 当前 euid、home =
 * /home/container 的 "container" 用户，于是校验恒成立，公钥认证照常进行
 * （authorized_keys 从 pw_dir=~/.ssh/ 读取）。
 */
static struct passwd pw;
static char n_user[] = "container";
static char n_passwd[] = "x";
static char n_gecos[] = "sandbox";
static char n_dir[] = "/home/container";
static char n_shell[] = "/bin/bash";

struct passwd *getpwnam(const char *name) {
    (void)name;
    memset(&pw, 0, sizeof(pw));
    pw.pw_name = n_user;
    pw.pw_passwd = n_passwd;
    pw.pw_uid = geteuid();
    pw.pw_gid = getegid();
    pw.pw_gecos = n_gecos;
    pw.pw_dir = n_dir;
    pw.pw_shell = n_shell;
    return &pw;
}

struct passwd *getpwuid(uid_t uid) {
    (void)uid;
    return getpwnam("container");
}
