/*
    threads.d -- Posix threads with support from GCC.
*/
/*
    Copyright (c) 2003, Juan Jose Garcia Ripoll.

    ECL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    See file '../Copyright' for full details.
*/
/*
 * IMPORTANT!!!! IF YOU EDIT THIS FILE, CHANGE ALSO threads_win32.d
 */

#include <pthread.h>
#include <signal.h>
#define GC_THREADS
#include <ecl/ecl.h>
#include <ecl/internal.h>

#ifndef WITH___THREAD
static pthread_key_t cl_env_key;
#endif

static pthread_t main_thread;

extern void ecl_init_env(struct cl_env_struct *env);

#ifndef WITH___THREAD
struct cl_env_struct *
ecl_process_env(void)
{
	struct cl_env_struct *rv = pthread_getspecific(cl_env_key);
        if (rv)
		return rv;
        FElibc_error("pthread_getspecific() failed.", 0);
        return NULL;
}
#endif

cl_object
mp_current_process(void)
{
	return cl_env.own_process;
}

/*----------------------------------------------------------------------
 * THREAD OBJECT
 */

static void
assert_type_process(cl_object o)
{
	if (type_of(o) != t_process)
		FEwrong_type_argument(@'mp::process', o);
}

static void
thread_cleanup(void *env)
{
	/* This routine performs some cleanup before a thread is completely
	 * killed. For instance, it has to remove the associated process
	 * object from the list, an it has to dealloc some memory.
	 *
	 * NOTE: thread_cleanup() does not provide enough "protection". In
	 * order to ensure that all UNWIND-PROTECT forms are properly
	 * executed, never use pthread_cancel() to kill a process, but
	 * rather use the lisp functions mp_interrupt_process() and
	 * mp_process_kill().
	 */
	THREAD_OP_LOCK();
	cl_core.processes = ecl_remove_eq(cl_env.own_process,
					  cl_core.processes);
	THREAD_OP_UNLOCK();
}

static void *
thread_entry_point(cl_object process)
{
	/* 1) Setup the environment for the execution of the thread */
	pthread_cleanup_push(thread_cleanup, (void *)process->process.env);
#ifdef WITH___THREAD
	cl_env_p = process->process.env;
#else
	if (pthread_setspecific(cl_env_key, process->process.env))
		FElibc_error("pthread_setcspecific() failed.", 0);
#endif
	ecl_init_env(process->process.env);
        init_big_registers();

	/* 2) Execute the code. The CATCH_ALL point is the destination
	*     provides us with an elegant way to exit the thread: we just
	*     do an unwind up to frs_top.
	*/
	process->process.active = 1;
	CL_CATCH_ALL_BEGIN {
		bds_bind(@'mp::*current-process*', process);
		cl_apply(2, process->process.function, process->process.args);
		bds_unwind1();
	} CL_CATCH_ALL_END;
	process->process.active = 0;

	/* 3) If everything went right, we should be exiting the thread
         *    through this point. thread_cleanup is automatically invoked.
	 */
	pthread_cleanup_pop(1);
	return NULL;
}

static cl_object
alloc_process(cl_object name)
{
	cl_object process = cl_alloc_object(t_process);
	process->process.active = 0;
	process->process.name = name;
	process->process.function = Cnil;
	process->process.args = Cnil;
	process->process.interrupt = Cnil;
	process->process.env = cl_alloc(sizeof(*process->process.env));
	process->process.env->own_process = process;
	return process;
}

static void
initialize_process_bindings(cl_object process, cl_object initial_bindings)
{
	cl_object hash;
	/* FIXME! Here we should either use INITIAL-BINDINGS or copy lexical
	 * bindings */
	if (initial_bindings != OBJNULL) {
		hash = cl__make_hash_table(@'eq', MAKE_FIXNUM(1024),
					   ecl_make_singlefloat(1.5),
					   ecl_make_singlefloat(0.7),
					   Cnil); /* no need for locking */
	} else {
		hash = si_copy_hash_table(cl_env.bindings_hash);
	}
	process->process.env->bindings_hash = hash;
}

void
ecl_import_current_thread(cl_object name, cl_object bindings)
{
	cl_object process = alloc_process(name);
#ifdef WITH___THREAD
	cl_env_p = process->process.env;
#else
	if (pthread_setspecific(cl_env_key, process->process.env))
		FElibc_error("pthread_setcspecific() failed.", 0);
#endif
	initialize_process_bindings(process, bindings);
	ecl_init_env(&cl_env);
        init_big_registers();
}

void
ecl_release_current_thread(void)
{
	thread_cleanup(&cl_env);
}

@(defun mp::make-process (&key name ((:initial-bindings initial_bindings) Ct))
	cl_object process;
@
	process = alloc_process(name);
	initialize_process_bindings(process, initial_bindings);
	@(return process)
@)

cl_object
mp_process_preset(cl_narg narg, cl_object process, cl_object function, ...)
{
	cl_va_list args;
	cl_va_start(args, function, narg, 2);
	if (narg < 2)
		FEwrong_num_arguments(@'mp::process-preset');
	assert_type_process(process);
	process->process.function = function;
	process->process.args = cl_grab_rest_args(args);
	@(return process)
}

cl_object
mp_interrupt_process(cl_object process, cl_object function)
{
	if (mp_process_active_p(process) == Cnil)
		FEerror("Cannot interrupt the inactive process ~A", 1, process);
	process->process.interrupt = function;
	if ( pthread_kill(process->process.thread, SIGUSR1) )
		FElibc_error("pthread_kill() failed.", 0);
        @(return Ct)
}

cl_object
mp_process_kill(cl_object process)
{
	mp_interrupt_process(process, @'mp::exit-process');
        @(return Ct)
}

cl_object
mp_process_enable(cl_object process)
{
	pthread_t *posix_thread;
	int code;

	if (mp_process_active_p(process) != Cnil)
		FEerror("Cannot enable the running process ~A.", 1, process);
	THREAD_OP_LOCK();
	code = pthread_create(&process->process.thread, NULL, thread_entry_point, process);
	if (!code) {
		/* If everything went ok, add the thread to the list. */
		cl_core.processes = CONS(process, cl_core.processes);
	} /* FIXME: how to do FElibc_error() without leaving a lock? */
	THREAD_OP_UNLOCK();
	@(return (code? Cnil : process))
}

cl_object
mp_exit_process(void)
{
	if (pthread_equal(pthread_self(), main_thread)) {
		/* This is the main thread. Quitting it means exiting the
		   program. */
		si_quit(0);
	} else {
		/* We simply undo the whole of the frame stack. This brings up
		   back to the thread entry point, going through all possible
		   UNWIND-PROTECT.
		*/
		ecl_unwind(cl_env.frs_org);
	}
}

cl_object
mp_all_processes(void)
{
     /* Isn't it a race condition? */
	@(return cl_copy_list(cl_core.processes))
}

cl_object
mp_process_name(cl_object process)
{
	assert_type_process(process);
	@(return process->process.name)
}

cl_object
mp_process_active_p(cl_object process)
{
	assert_type_process(process);
	@(return (process->process.active? Ct : Cnil))
}

cl_object
mp_process_whostate(cl_object process)
{
	assert_type_process(process);
	@(return (cl_core.null_string))
}

cl_object
mp_process_run_function(cl_narg narg, cl_object name, cl_object function, ...)
{
	cl_object process;
	cl_va_list args;
	cl_va_start(args, function, narg, 2);
	if (narg < 2)
		FEwrong_num_arguments(@'mp::process-run-function');
	if (CONSP(name)) {
		process = cl_apply(2, @'mp::make-process', name);
	} else {
		process = mp_make_process(2, @':name', name);
	}
	cl_apply(4, @'mp::process-preset', process, function,
		 cl_grab_rest_args(args));
	return mp_process_enable(process);
}

/*----------------------------------------------------------------------
 * LOCKS or MUTEX
 */

@(defun mp::make-lock (&key name)
	pthread_mutexattr_t attr;
	cl_object output;
@
	pthread_mutexattr_init(&attr);
	pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE_NP);
	output = cl_alloc_object(t_lock);
	output->lock.name = name;
	pthread_mutex_init(&output->lock.mutex, &attr);
	pthread_mutexattr_destroy(&attr);
        si_set_finalizer(output, Ct);
	@(return output)
@)

cl_object
mp_giveup_lock(cl_object lock)
{
	if (type_of(lock) != t_lock)
		FEwrong_type_argument(@'mp::lock', lock);
	pthread_mutex_unlock(&lock->lock.mutex);
	@(return Ct)
}

@(defun mp::get-lock (lock &optional (wait Ct))
	cl_object output;
@
	if (type_of(lock) != t_lock)
		FEwrong_type_argument(@'mp::lock', lock);
	if (wait == Ct) {
		pthread_mutex_lock(&lock->lock.mutex);
		output = Ct;
	} else if (pthread_mutex_trylock(&lock->lock.mutex) == 0) {
		output = Ct;
	} else {
		output = Cnil;
	}
	@(return output)
@)

void
init_threads()
{
	cl_object process;
	struct cl_env_struct *env;
	pthread_mutexattr_t attr;

	cl_core.processes = OBJNULL;
	pthread_mutexattr_init(&attr);
	pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ERRORCHECK_NP);
	pthread_mutex_init(&cl_core.global_lock, &attr);
	pthread_mutexattr_destroy(&attr);

	process = cl_alloc_object(t_process);
	process->process.active = 1;
	process->process.name = @'si::top-level';
	process->process.function = Cnil;
	process->process.args = Cnil;
	process->process.thread = pthread_self();
	process->process.env = env = cl_alloc(sizeof(*env));

#ifdef WITH___THREAD
        cl_env_p = env;
#else
	pthread_key_create(&cl_env_key, NULL);
	pthread_setspecific(cl_env_key, env);
#endif
	env->own_process = process;

	cl_core.processes = CONS(process, Cnil);

	main_thread = pthread_self();
}
