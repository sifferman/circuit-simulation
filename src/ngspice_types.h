#ifndef NGSPICE_TYPES_H
#define NGSPICE_TYPES_H

// Minimal type definitions for the ngspice shared-library interface.
// These match the ABI defined in ngspice's sharedspice.h so we can
// dynamically load ngspice without shipping its header.

#ifdef __cplusplus
extern "C" {
#endif

struct ngcomplex {
    double cx_real;
    double cx_imag;
};
typedef struct ngcomplex ngcomplex_t;

typedef struct vector_info {
    char *v_name;
    int v_type;
    short v_flags;
    double *v_realdata;
    ngcomplex_t *v_compdata;
    int v_length;
} vector_info, *pvector_info;

typedef struct vecvalues {
    char* name;
    double creal;
    double cimag;
    bool is_scale;
    bool is_complex;
} vecvalues, *pvecvalues;

typedef struct vecvaluesall {
    int veccount;
    int vecindex;
    pvecvalues *vecsa;
} vecvaluesall, *pvecvaluesall;

typedef struct vecinfo {
    int number;
    char *vecname;
    bool is_real;
    void *pdvec;
    void *pdvecscale;
} vecinfo, *pvecinfo;

typedef struct vecinfoall {
    char *name;
    char *title;
    char *date;
    char *type;
    int veccount;
    pvecinfo *vecs;
} vecinfoall, *pvecinfoall;

// Callback function typedefs
typedef int (SendChar)(char*, int, void*);
typedef int (SendStat)(char*, int, void*);
typedef int (ControlledExit)(int, bool, bool, int, void*);
typedef int (SendData)(pvecvaluesall, int, int, void*);
typedef int (SendInitData)(pvecinfoall, int, void*);
typedef int (BGThreadRunning)(bool, int, void*);
typedef int (GetVSRCData)(double*, double, char*, int, void*);
typedef int (GetISRCData)(double*, double, char*, int, void*);
typedef int (GetSyncData)(double, double*, double, int, int, int, void*);

#ifdef __cplusplus
}
#endif

#endif // NGSPICE_TYPES_H
