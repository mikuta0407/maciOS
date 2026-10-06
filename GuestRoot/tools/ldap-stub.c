// Stand-in for LDAP.framework, which iOS lacks: every call fails, so
// programs linked against it (libcurl) treat LDAP as unavailable.
#include <stddef.h>
#define LDAP_OTHER 0x50
#define LDAP_OPT_ERROR (-1)
#define LDAP_URL_ERR_MEM 1
void *ldap_init(const char *host, int port) { return NULL; }
int ldap_get_option(void *ld, int option, void *out) { return LDAP_OPT_ERROR; }
int ldap_set_option(void *ld, int option, const void *in) { return LDAP_OPT_ERROR; }
int ldap_simple_bind_s(void *ld, const char *who, const char *passwd) { return LDAP_OTHER; }
int ldap_search_s(void *ld, const char *base, int scope, const char *filter, char **attrs, int attrsonly, void **res) { if (res) *res = NULL; return LDAP_OTHER; }
int ldap_unbind_s(void *ld) { return LDAP_OTHER; }
char *ldap_err2string(int err) { return "LDAP is not available"; }
int ldap_url_parse(const char *url, void **desc) { if (desc) *desc = NULL; return LDAP_URL_ERR_MEM; }
void ldap_free_urldesc(void *desc) {}
void *ldap_first_entry(void *ld, void *chain) { return NULL; }
void *ldap_next_entry(void *ld, void *entry) { return NULL; }
char *ldap_first_attribute(void *ld, void *entry, void **ber) { if (ber) *ber = NULL; return NULL; }
char *ldap_next_attribute(void *ld, void *entry, void *ber) { return NULL; }
char *ldap_get_dn(void *ld, void *entry) { return NULL; }
void **ldap_get_values_len(void *ld, void *entry, const char *target) { return NULL; }
void ldap_value_free_len(void **vals) {}
void ldap_memfree(void *p) {}
int ldap_msgfree(void *msg) { return 0; }
void ber_free(void *ber, int freebuf) {}
void ber_memvfree(void **vec) {}
