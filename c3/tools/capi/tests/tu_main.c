/* One of two translation units that include the whole public header and are linked together. */
#include <bleu/bleu.h>
#include <stdio.h>

int tu_other_check(void);

int main(void)
{
    if (BLEU_ABI_VERSION != bleu_abi_version()) {
        printf("abi mismatch\n");
        return 1;
    }
    if (tu_other_check() != 0) return 1;
    printf("two translation units: ok\n");
    return 0;
}
