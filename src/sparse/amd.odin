package sparse

import "base:runtime"
import "core:math"

// The approximate minimum degree order (Amestoy, Davis and Duff, "An approximate minimum
// degree ordering algorithm", 1996), ported from SuiteSparse's AMD (amd_1, amd_2,
// amd_postorder and amd_post_tree), which is under the BSD 3-clause licence:
//
//   AMD, Copyright (c), 1996-2022, Timothy A. Davis, Patrick R. Amestoy, and Iain S. Duff.
//   All Rights Reserved. Redistribution and use in source and binary forms, with or
//   without modification, are permitted provided that the following conditions are met:
//   redistributions of source code must retain the above copyright notice, this list of
//   conditions and the following disclaimer; redistributions in binary form must
//   reproduce the above copyright notice, this list of conditions and the following
//   disclaimer in the documentation and/or other materials provided with the
//   distribution; neither the name of the organizations to which the authors are
//   affiliated, nor the names of its contributors may be used to endorse or promote
//   products derived from this software without specific prior written permission.
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
//   EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED (the full text is in
//   assets/licenses/SuiteSparse-AMD-LICENSE.txt).
//
// It is AMD with its defaults (aggressive absorption, rows denser than ten times the
// square root of n ordered last), the statistics left out. Eigen's sparse LDLᵀ, which the
// C++ core solves with, orders by the same algorithm, so the two factors have about the
// same fill.

@(private = "file")
EMPTY :: -1

@(private = "file")
flip :: #force_inline proc(i: int) -> int {
	return -i - 2
}

// The order in which to eliminate the unknowns: `order[k]` is the unknown eliminated k-th
// and `inverse` its inverse. Only the pattern of the matrix is read. `room` is the
// workspace's spare entries beyond the graph and one per unknown (a fifth of the graph by
// default, as SuiteSparse sizes it); less only makes it compress its workspace more
// often, which the tests use to check that the order does not change.
amd_order :: proc(m: Symmetric, allocator := context.allocator, room := -1) -> (order, inverse: []i32) {
	heap := runtime.heap_allocator()
	n := m.n
	order = make([]i32, n, allocator)
	inverse = make([]i32, n, allocator)
	if n == 0 do return

	// The pattern of A + Aᵀ without the diagonal, each unknown's neighbours together (amd_1).
	len_ := make([]int, n, heap)
	defer delete(len_, heap)
	for j in 0 ..< n {
		for p in m.first[j] ..< m.first[j + 1] {
			i := int(m.rows[p])
			if i == j do continue
			len_[i] += 1
			len_[j] += 1
		}
	}
	pfree := 0
	for l in len_ do pfree += l
	iwlen := pfree + (room if room >= 0 else pfree / 5) + n
	iw := make([]int, iwlen, heap)
	defer delete(iw, heap)
	pe := make([]int, n, heap)
	defer delete(pe, heap)
	{
		at := 0
		for j in 0 ..< n {
			pe[j] = at
			at += len_[j]
		}
		fill := make([]int, n, heap)
		defer delete(fill, heap)
		copy(fill, pe)
		for j in 0 ..< n {
			for p in m.first[j] ..< m.first[j + 1] {
				i := int(m.rows[p])
				if i == j do continue
				iw[fill[i]] = j
				fill[i] += 1
				iw[fill[j]] = i
				fill[j] += 1
			}
		}
	}

	nv := make([]int, n, heap)
	defer delete(nv, heap)
	next := make([]int, n, heap)
	defer delete(next, heap)
	last := make([]int, n, heap)
	defer delete(last, heap)
	head := make([]int, n, heap)
	defer delete(head, heap)
	elen := make([]int, n, heap)
	defer delete(elen, heap)
	degree := make([]int, n, heap)
	defer delete(degree, heap)
	w := make([]int, n, heap)
	defer delete(w, heap)
	amd_2(n, pe, iw, len_, iwlen, pfree, nv, next, last, head, elen, degree, w)
	for k in 0 ..< n do order[k] = i32(last[k])
	for i in 0 ..< n do inverse[i] = i32(next[i])
	return
}

@(private = "file")
clear_flag :: proc(wflg, wbig: int, w: []int) -> int {
	if wflg < 2 || wflg >= wbig {
		for &x in w do if x != 0 do x = 1
		return 2
	}
	return wflg
}

// The minimum degree elimination over the quotient graph, as amd_2 does it; on return
// `last` holds the order and `next` its inverse.
@(private = "file")
amd_2 :: proc(n: int, pe, iw, len_: []int, iwlen, pfree_in: int, nv, next, last, head, elen, degree, w: []int) {
	pfree := pfree_in
	me := EMPTY
	mindeg := 0
	nel := 0
	lemax := 0
	dense := int(10 * math.sqrt(f64(n)))
	dense = min(n, max(16, dense))
	for i in 0 ..< n {
		last[i] = EMPTY
		head[i] = EMPTY
		next[i] = EMPTY
		nv[i] = 1
		w[i] = 1
		elen[i] = 0
		degree[i] = len_[i]
	}
	wbig := max(int) - n
	wflg := clear_flag(0, wbig, w)
	ndense := 0
	for i in 0 ..< n {
		deg := degree[i]
		if deg == 0 {
			elen[i] = flip(1)
			nel += 1
			pe[i] = EMPTY
			w[i] = 0
		} else if deg > dense {
			ndense += 1
			nv[i] = 0
			elen[i] = EMPTY
			nel += 1
			pe[i] = EMPTY
		} else {
			inext := head[deg]
			if inext != EMPTY do last[inext] = i
			next[i] = inext
			head[deg] = i
		}
	}

	for nel < n {
		// The pivot: a variable of least approximate degree.
		deg := mindeg
		for ; deg < n; deg += 1 {
			me = head[deg]
			if me != EMPTY do break
		}
		mindeg = deg
		inext := next[me]
		if inext != EMPTY do last[inext] = EMPTY
		head[deg] = inext
		elenme := elen[me]
		nvpiv := nv[me]
		nel += nvpiv
		nv[me] = -nvpiv
		degme := 0
		pme1, pme2: int

		// The new element: me's variables and those of the elements it absorbs.
		if elenme == 0 {
			pme1 = pe[me]
			pme2 = pme1 - 1
			for p in pme1 ..= pme1 + len_[me] - 1 {
				i := iw[p]
				nvi := nv[i]
				if nvi > 0 {
					degme += nvi
					nv[i] = -nvi
					pme2 += 1
					iw[pme2] = i
					ilast, inext2 := last[i], next[i]
					if inext2 != EMPTY do last[inext2] = ilast
					if ilast != EMPTY do next[ilast] = inext2
					else do head[degree[i]] = inext2
				}
			}
		} else {
			p := pe[me]
			pme1 = pfree
			slenme := len_[me] - elenme
			for knt1 in 1 ..= elenme + 1 {
				e, pj, ln: int
				if knt1 > elenme {
					e, pj, ln = me, p, slenme
				} else {
					e = iw[p]
					p += 1
					pj, ln = pe[e], len_[e]
				}
				for knt2 in 1 ..= ln {
					i := iw[pj]
					pj += 1
					nvi := nv[i]
					if nvi <= 0 do continue
					if pfree >= iwlen {
						// Out of room: compress iw, the elements and variables still in use
						// moved to its front.
						pe[me] = p
						len_[me] -= knt1
						if len_[me] == 0 do pe[me] = EMPTY
						pe[e] = pj
						len_[e] = ln - knt2
						if len_[e] == 0 do pe[e] = EMPTY
						for j in 0 ..< n {
							pn := pe[j]
							if pn >= 0 {
								pe[j] = iw[pn]
								iw[pn] = flip(j)
							}
						}
						psrc, pdst := 0, 0
						pend := pme1 - 1
						for psrc <= pend {
							j := flip(iw[psrc])
							psrc += 1
							if j >= 0 {
								iw[pdst] = pe[j]
								pe[j] = pdst
								pdst += 1
								lenj := len_[j]
								for _ in 0 ..= lenj - 2 {
									iw[pdst] = iw[psrc]
									pdst += 1
									psrc += 1
								}
							}
						}
						p1 := pdst
						for psrc2 in pme1 ..= pfree - 1 {
							iw[pdst] = iw[psrc2]
							pdst += 1
						}
						pme1 = p1
						pfree = pdst
						pj = pe[e]
						p = pe[me]
					}
					degme += nvi
					nv[i] = -nvi
					iw[pfree] = i
					pfree += 1
					ilast, inext2 := last[i], next[i]
					if inext2 != EMPTY do last[inext2] = ilast
					if ilast != EMPTY do next[ilast] = inext2
					else do head[degree[i]] = inext2
				}
				if e != me {
					pe[e] = flip(me)
					w[e] = 0
				}
			}
			pme2 = pfree - 1
		}
		degree[me] = degme
		pe[me] = pme1
		len_[me] = pme2 - pme1 + 1
		elen[me] = flip(nvpiv + degme)

		// |Le \ Lme| for every element e next to a variable of me.
		wflg = clear_flag(wflg, wbig, w)
		for pme in pme1 ..= pme2 {
			i := iw[pme]
			eln := elen[i]
			if eln <= 0 do continue
			nvi := -nv[i]
			wnvi := wflg - nvi
			for p in pe[i] ..= pe[i] + eln - 1 {
				e := iw[p]
				we := w[e]
				if we >= wflg do we -= nvi
				else if we != 0 do we = degree[e] + wnvi
				w[e] = we
			}
		}

		// The approximate degree of each variable of me, elements absorbed aggressively, and
		// each variable hashed for the search for indistinguishable ones.
		for pme in pme1 ..= pme2 {
			i := iw[pme]
			p1 := pe[i]
			p2 := p1 + elen[i] - 1
			pn := p1
			hash := u64(0)
			ideg := 0
			for p in p1 ..= p2 {
				e := iw[p]
				we := w[e]
				if we == 0 do continue
				dext := we - wflg
				if dext > 0 {
					ideg += dext
					iw[pn] = e
					pn += 1
					hash += u64(e)
				} else {
					pe[e] = flip(me)
					w[e] = 0
				}
			}
			elen[i] = pn - p1 + 1
			p3 := pn
			p4 := p1 + len_[i]
			for p in p2 + 1 ..< p4 {
				j := iw[p]
				nvj := nv[j]
				if nvj > 0 {
					ideg += nvj
					iw[pn] = j
					pn += 1
					hash += u64(j)
				}
			}
			if elen[i] == 1 && p3 == pn {
				// Absorbed into me entirely (mass elimination).
				pe[i] = flip(me)
				nvi := -nv[i]
				degme -= nvi
				nvpiv += nvi
				nel += nvi
				nv[i] = 0
				elen[i] = EMPTY
			} else {
				degree[i] = min(degree[i], ideg)
				iw[pn] = iw[p3]
				iw[p3] = iw[p1]
				iw[p1] = me
				len_[i] = pn - p1 + 1
				h := int(hash % u64(n))
				j := head[h]
				if j <= EMPTY {
					next[i] = flip(j)
					head[h] = flip(i)
				} else {
					next[i] = last[j]
					last[j] = i
				}
				last[i] = h
			}
		}
		degree[me] = degme
		lemax = max(lemax, degme)
		wflg += lemax
		wflg = clear_flag(wflg, wbig, w)

		// Supervariables: variables of me with the same elements and neighbours merge.
		for pme in pme1 ..= pme2 {
			i := iw[pme]
			if nv[i] >= 0 do continue
			h := last[i]
			j := head[h]
			if j == EMPTY {
				i = EMPTY
			} else if j < EMPTY {
				i = flip(j)
				head[h] = EMPTY
			} else {
				i = last[j]
				last[j] = EMPTY
			}
			for i != EMPTY && next[i] != EMPTY {
				ln := len_[i]
				eln := elen[i]
				for p in pe[i] + 1 ..= pe[i] + ln - 1 do w[iw[p]] = wflg
				jlast := i
				j = next[i]
				for j != EMPTY {
					ok := len_[j] == ln && elen[j] == eln
					for p := pe[j] + 1; ok && p <= pe[j] + ln - 1; p += 1 do if w[iw[p]] != wflg do ok = false
					if ok {
						pe[j] = flip(i)
						nv[i] += nv[j]
						nv[j] = 0
						elen[j] = EMPTY
						j = next[j]
						next[jlast] = j
					} else {
						jlast = j
						j = next[j]
					}
				}
				wflg += 1
				i = next[i]
			}
		}

		// The variables of me back in the degree lists, me's list left with them.
		p := pme1
		nleft := n - nel
		for pme in pme1 ..= pme2 {
			i := iw[pme]
			nvi := -nv[i]
			if nvi <= 0 do continue
			nv[i] = nvi
			deg2 := min(degree[i] + degme - nvi, nleft - nvi)
			inext2 := head[deg2]
			if inext2 != EMPTY do last[inext2] = i
			next[i] = inext2
			last[i] = EMPTY
			head[deg2] = i
			mindeg = min(mindeg, deg2)
			degree[i] = deg2
			iw[p] = i
			p += 1
		}
		nv[me] = nvpiv
		len_[me] = p - pme1
		if len_[me] == 0 {
			pe[me] = EMPTY
			w[me] = 0
		}
		if elenme != 0 do pfree = p
	}

	// The assembly tree: each absorbed variable and element under the element that took it.
	for i in 0 ..< n do pe[i] = flip(pe[i])
	for i in 0 ..< n do elen[i] = flip(elen[i])
	for i in 0 ..< n {
		if nv[i] != 0 do continue
		j := pe[i]
		if j == EMPTY do continue
		for nv[j] == 0 do j = pe[j]
		e := j
		j = i
		for nv[j] == 0 {
			jnext := pe[j]
			pe[j] = e
			j = jnext
		}
	}
	amd_postorder(n, pe, nv, elen, w, head, next, last)
	for k in 0 ..< n {
		head[k] = EMPTY
		next[k] = EMPTY
	}
	for e in 0 ..< n {
		k := w[e]
		if k != EMPTY do head[k] = e
	}
	nel = 0
	for k in 0 ..< n {
		e := head[k]
		if e == EMPTY do break
		next[e] = nel
		nel += nv[e]
	}
	for i in 0 ..< n {
		if nv[i] != 0 do continue
		e := pe[i]
		if e != EMPTY {
			next[i] = next[e]
			next[e] += 1
		} else {
			next[i] = nel
			nel += 1
		}
	}
	for i in 0 ..< n do last[next[i]] = i
}

// The elements in postorder, each one's largest child (by front size) last.
@(private = "file")
amd_postorder :: proc(n: int, parent, nv, fsize, order, child, sibling, stack: []int) {
	for j in 0 ..< n {
		child[j] = EMPTY
		sibling[j] = EMPTY
	}
	for j := n - 1; j >= 0; j -= 1 {
		if nv[j] <= 0 do continue
		p := parent[j]
		if p != EMPTY {
			sibling[j] = child[p]
			child[p] = j
		}
	}
	for i in 0 ..< n {
		if nv[i] <= 0 || child[i] == EMPTY do continue
		fprev, maxfrsize, bigfprev, bigf := EMPTY, EMPTY, EMPTY, EMPTY
		for f := child[i]; f != EMPTY; f = sibling[f] {
			frsize := fsize[f]
			if frsize >= maxfrsize {
				maxfrsize = frsize
				bigfprev = fprev
				bigf = f
			}
			fprev = f
		}
		fnext := sibling[bigf]
		if fnext != EMPTY {
			if bigfprev == EMPTY do child[i] = fnext
			else do sibling[bigfprev] = fnext
			sibling[bigf] = EMPTY
			sibling[fprev] = bigf
		}
	}
	for i in 0 ..< n do order[i] = EMPTY
	k := 0
	for i in 0 ..< n {
		if parent[i] != EMPTY || nv[i] <= 0 do continue
		// A depth-first walk with a stack of its own (amd_post_tree).
		top := 0
		stack[0] = i
		for top >= 0 {
			v := stack[top]
			if child[v] != EMPTY {
				for f := child[v]; f != EMPTY; f = sibling[f] do top += 1
				h := top
				for f := child[v]; f != EMPTY; f = sibling[f] {
					stack[h] = f
					h -= 1
				}
				child[v] = EMPTY
			} else {
				top -= 1
				order[v] = k
				k += 1
			}
		}
	}
}
