/*
 * my_extension.c - C-language functions for the teaching extension.
 *
 *   my_add(int, int)             integer addition that raises an error on overflow
 *   my_distance(my_point, ...)   euclidean distance between two composite values
 */
#include "postgres.h"

#include <math.h>

#include "common/int.h"
#include "executor/executor.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(my_add);
PG_FUNCTION_INFO_V1(my_distance);

Datum
my_add(PG_FUNCTION_ARGS)
{
	int32		a = PG_GETARG_INT32(0);
	int32		b = PG_GETARG_INT32(1);
	int32		result;

	if (pg_add_s32_overflow(a, b, &result))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("integer out of range")));
	PG_RETURN_INT32(result);
}

Datum
my_distance(PG_FUNCTION_ARGS)
{
	HeapTupleHeader p1 = PG_GETARG_HEAPTUPLEHEADER(0);
	HeapTupleHeader p2 = PG_GETARG_HEAPTUPLEHEADER(1);
	bool		null_x1, null_y1, null_x2, null_y2;
	double		x1 = DatumGetFloat8(GetAttributeByNum(p1, 1, &null_x1));
	double		y1 = DatumGetFloat8(GetAttributeByNum(p1, 2, &null_y1));
	double		x2 = DatumGetFloat8(GetAttributeByNum(p2, 1, &null_x2));
	double		y2 = DatumGetFloat8(GetAttributeByNum(p2, 2, &null_y2));

	if (null_x1 || null_y1 || null_x2 || null_y2)
		PG_RETURN_NULL();

	PG_RETURN_FLOAT8(sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)));
}
