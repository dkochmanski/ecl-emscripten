/*
    gfun.c -- Dispatch for generic functions.
*/
/*
    Copyright (c) 1990, Giuseppe Attardi.

    ECL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    See file '../Copyright' for full details.
*/

#include <string.h>
#include <ecl/ecl.h>
#include <ecl/internal.h>
#include "newhash.h"

static cl_object
do_clear_gfun_hash(cl_object target)
{
	cl_object table = cl_env.gfun_hash;
	if (target == Ct) {
		cl_clrhash(table);
	} else {
		cl_index hsize = table->hash.size;
		struct ecl_hashtable_entry *htable = table->hash.data;
		for (; hsize; htable++, hsize--) {
			if (htable->key != OBJNULL) {
				cl_object gfun = CAR(htable->key);
				if (gfun == target) {
					htable->key = OBJNULL;
					htable->value = OBJNULL;
					table->hash.entries--;
				}
			}
		}
	}
}

cl_object
si_clear_gfun_hash(cl_object what)
{
	/*
	 * This function clears the generic function call hashes selectively.
	 *	what = Ct means clear the hash completely
	 *	what = generic function, means cleans only these entries
	 * If we work on a multithreaded environment, we simply enqueue these
	 * operations and wait for the destination thread to update its own hash.
	 */
#ifdef ECL_THREADS
	cl_object list;
	THREAD_OP_LOCK();
	list = cl_core.processes;
	for (; list != Cnil; list = CDR(list)) {
		cl_object process = CAR(list);
		struct cl_env_struct *env = process->process.env;
		env->gfun_hash_clear_list = CONS(what, env->gfun_hash_clear_list);
	}
	THREAD_OP_UNLOCK();
#else
	do_clear_gfun_hash(what);
#endif
}

static void
reshape_instance(cl_object x, int delta)
{
	cl_fixnum size = x->instance.length + delta;
	cl_object aux = ecl_allocate_instance(CLASS_OF(x), size);
	memcpy(aux->instance.slots, x->instance.slots,
	       (delta < 0 ? aux->instance.length : x->instance.length) *
	       sizeof(cl_object));
	x->instance = aux->instance;
}

/* this turns any instance into a funcallable (apart from a builtin generic function)
   or back into an ordinary instance */

cl_object
si_set_raw_funcallable(cl_object instance, cl_object function)
{
	if (type_of(instance) != t_instance)
		FEwrong_type_argument(@'ext::instance', instance);
        if (Null(function)) {
		if (instance->instance.isgf == 2) {
                        int        length          = instance->instance.length-1;
                        cl_object *slots           = (cl_object*)cl_alloc(sizeof(cl_object)*(length));
			instance->instance.isgf    = 2;
                        memcpy(slots, instance->instance.slots, sizeof(cl_object)*(length));
			instance->instance.slots   = slots;
			instance->instance.length  = length;
		        instance->instance.isgf = 0;
		}
	} else	{
		if (instance->instance.isgf == 0) {
                        int        length          = instance->instance.length+1;
                        cl_object *slots           = (cl_object*)cl_alloc(sizeof(cl_object)*length);
                        memcpy(slots, instance->instance.slots, sizeof(cl_object)*(length-1));
			instance->instance.slots   = slots;
			instance->instance.length  = length;
			instance->instance.isgf    = 2;
		}
		instance->instance.slots[instance->instance.length-1] = function;
	}
	@(return instance)
}

cl_object
clos_set_funcallable_instance_function(cl_object x, cl_object function_or_t)
{
	if (type_of(x) != t_instance)
		FEwrong_type_argument(@'ext::instance', x);
	if (x->instance.isgf == ECL_USER_DISPATCH) {
		reshape_instance(x, -1);
		x->instance.isgf = ECL_NOT_FUNCALLABLE;
	}
	if (function_or_t == Ct)
	{
		x->instance.isgf = ECL_STANDARD_DISPATCH;
	} else if (function_or_t == Cnil) {
		x->instance.isgf = ECL_NOT_FUNCALLABLE;
	} else if (Null(cl_functionp(function_or_t))) {
		FEwrong_type_argument(@'function', function_or_t);
	} else {
		reshape_instance(x, +1);
		x->instance.slots[x->instance.length - 1] = function_or_t;
		x->instance.isgf = ECL_USER_DISPATCH;
	}
	@(return x)
}

cl_object
si_generic_function_p(cl_object x)
{
	@(return (((type_of(x) != t_instance) &&
		   (x->instance.isgf))? Ct : Cnil))
}

/*
 * variation of ecl_gethash from hash.d, which takes an array of objects as key
 * It also assumes that entries are never removed except by clrhash.
 */

static struct ecl_hashtable_entry *
get_meth_hash(cl_object *keys, int argno, cl_object hashtable)
{
	cl_index hsize;
	struct ecl_hashtable_entry *e, *htable;
	cl_object hkey, tlist;
	register cl_index i;
	int k, n;

	for (i = 0, n = 0; n < argno; n++) {
		register cl_index a = (cl_index)keys[n];
		register cl_index b = GOLDEN_RATIO;
		mix(a, b, i);
	}

	hsize = hashtable->hash.size;
	htable = hashtable->hash.data;
	i = i % hsize;
	for (k = 0; k < hsize; k++) {
		bool b = 1;
		e = &htable[i];
		hkey = e->key;
		if (hkey == OBJNULL)
			return(e);
		for (b = 1, n = 0, tlist = hkey; b && (n < argno);
		     n++, tlist = CDR(tlist))
			b &= (keys[n] == CAR(tlist));
		if (b)
			return(&htable[i]);
		if (++i >= hsize) i = 0;
	}
	ecl_internal_error("get_meth_hash");
}

static void
set_meth_hash(cl_object *keys, int argno, cl_object hashtable, cl_object value)
{
	struct ecl_hashtable_entry *e;
	cl_object keylist, *p;
	cl_index i;

	i = hashtable->hash.entries + 1;
	if (i >= hashtable->hash.size ||
	    i >= (hashtable->hash.size * hashtable->hash.factor)) {
		if (hashtable->hash.size > 4092) {
			/* It does not make sense to let these hashes grow large */
			cl_clrhash(hashtable);
		} else {
			ecl_extend_hashtable(hashtable);
		}
	}
	keylist = Cnil;
	for (p = keys + argno; p > keys; p--) keylist = CONS(p[-1], keylist);
	e = get_meth_hash(keys, argno, hashtable);
	if (e->key == OBJNULL) {
		e->key = keylist;
		hashtable->hash.entries++;
	}
	e->value = value;
}

static cl_object
standard_dispatch(cl_narg narg, cl_object gf, cl_object *args)
{
	int i, spec_no;
	struct ecl_hashtable_entry *e;
	cl_object spec_how_list = GFUN_SPEC(gf);
	cl_object table = cl_env.gfun_hash;
	cl_object argtype[1+LAMBDA_PARAMETERS_LIMIT];

#ifdef ECL_THREADS
	/* See whether we have to clear the hash from some generic functions right now. */
	if (cl_env.gfun_hash_clear_list != Cnil) {
		cl_object clear_list;
		THREAD_OP_LOCK();
		clear_list = cl_env.gfun_hash_clear_list;
		for ( ; clear_list != Cnil ; clear_list = CDR(clear_list)) {
			do_clear_gfun_hash(CAR(clear_list));
		}
		cl_env.gfun_hash_clear_list = Cnil;
		THREAD_OP_UNLOCK();
	}
#endif
	argtype[0] = gf;
	for (spec_no = 1; spec_how_list != Cnil;) {
		cl_object spec_how = CAR(spec_how_list);
		cl_object spec_type = CAR(spec_how);
		int spec_position = fix(CDR(spec_how));
		if (spec_position >= narg)
			FEwrong_num_arguments(gf);
		argtype[spec_no++] =
			(ATOM(spec_type) ||
			 Null(ecl_memql(args[spec_position], spec_type))) ?
			cl_class_of(args[spec_position]) :
			args[spec_position];
		spec_how_list = CDR(spec_how_list);
	}

	e = get_meth_hash(argtype, spec_no, table);

	if (e->key != OBJNULL) {
		return e->value;
	} else {
		/* method not cached */
		cl_object methods, arglist, func;
		for (i = narg, arglist = Cnil; i-- > 0; ) {
			arglist = CONS(args[i], arglist);
		}
		
		methods = funcall(3, @'compute-applicable-methods', gf,
				  arglist);
		if (methods == Cnil) {
			func = funcall(3, @'no-applicable-method', gf,
				       arglist);
			args[0] = 0;
			return func;
		}
		func = funcall(4, @'clos::compute-effective-method', gf,
			       GFUN_COMB(gf), methods);
		/* update cache */
		set_meth_hash(argtype, spec_no, table, func);
		return func;
	}
}

cl_object
_ecl_compute_method(cl_narg narg, cl_object gf, cl_object *args)
{
	switch (gf->instance.isgf) {
	case ECL_STANDARD_DISPATCH:
		return standard_dispatch(narg, gf, args);
	case ECL_USER_DISPATCH:
		return gf->instance.slots[gf->instance.length - 1];
	default:
		FEinvalid_function(gf);
	}
}
