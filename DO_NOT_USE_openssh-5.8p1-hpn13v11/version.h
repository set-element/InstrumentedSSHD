/* $OpenBSD: version.h,v 1.61 2011/02/04 00:44:43 djm Exp $ */

#define SSH_VERSION	"OpenSSH_5.8"

#define SSH_PORTABLE	"p2"
#define SSH_HPN         "-hpn13v11"
#define SSH_RELEASE	SSH_VERSION SSH_PORTABLE SSH_HPN

#ifdef NERSC_MOD
#undef SSH_RELEASE
#define SSH_AUDITING	"NMOD_3.10"
#define SSH_RELEASE	SSH_VERSION SSH_PORTABLE SSH_AUDITING SSH_HPN
#endif /* NERSC_MOD */