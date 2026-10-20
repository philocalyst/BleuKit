<*
 Structural equality of plain-data state.

 Services publish a new snapshot only when the state actually changed. Because
 every state type is plain data (scalars, enums, typedefs, strings, slices and
 structs of those), one reflective comparison serves them all.
*>
module bleu::equal;

<*
 True when `a` and `b` hold the same data: strings and slices element by
 element, structs member by member, everything else with `==`.

 A float compares equal to itself when it is NaN, so an unchanged state that holds
 a NaN is not republished. Zero and negative zero compare equal.

 @require $Typeof(a) == $Typeof(b) : "both sides must have the same type"
*>
macro bool deep(a, b)
{
	var $Type = $Typeof(a);
	$switch $Type::kind:
		$case FLOAT:
			return a == b || (a != a && b != b);
		$case STRUCT:
			$foreach $member : $Type::members:
				if (!deep(a.$member, b.$member)) return false;
			$endforeach
			return true;
		$case SLICE:
			if (a.len != b.len) return false;
			for (sz i = 0; i < a.len; i++)
			{
				if (!deep(a[i], b[i])) return false;
			}
			return true;
		$case ARRAY:
			for (sz i = 0; i < a.len; i++)
			{
				if (!deep(a[i], b[i])) return false;
			}
			return true;
		$default:
			return a == b;
	$endswitch
}