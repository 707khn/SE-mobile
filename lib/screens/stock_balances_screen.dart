import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/stock_balance_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// Остатки на складах по последней выгрузке из 1С: что, сколько и где.
class StockBalancesScreen extends StatefulWidget {
  const StockBalancesScreen({Key? key}) : super(key: key);

  @override
  State<StockBalancesScreen> createState() => _StockBalancesScreenState();
}

class _StockBalancesScreenState extends State<StockBalancesScreen> {
  final _search = TextEditingController();
  bool _loading = true;
  bool _searching = false;
  LoadProblem? _problem;
  StockBalanceSearch _info = const StockBalanceSearch();
  StockBalanceSearch? _found;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Без запроса — только когда грузили и не устарело ли.
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final info = await searchStockBalances('');
      if (!mounted) return;
      setState(() {
        _info = info;
        _problem = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  Future<void> _find() async {
    final query = _search.text.trim();
    if (query.length < 2) return;
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    try {
      final found = await searchStockBalances(query);
      if (!mounted) return;
      setState(() {
        _info = found;
        _found = found;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('problem_${problemOfAny(e).name}_title'.tr)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'sb_title'.tr, color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _body(),
    );
  }

  Widget _body() {
    final found = _found;
    final asOf = _info.asOf;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const Key('sb_search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _find(),
            decoration: InputDecoration(
              hintText: 'sb_hint'.tr,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                key: const Key('sb_search_go'),
                icon: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_forward),
                onPressed: _searching ? null : _find,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            asOf == null
                ? 'sb_never'.tr
                : 'sb_as_of'.trParams(
                    {'date': DateFormat('dd.MM.yyyy HH:mm').format(asOf)}),
            style: TextStyle(fontSize: 12, color: context.mutedColor),
          ),
        ),
        if (_info.stale)
          Container(
            key: const Key('sb_stale'),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFE65100).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('sb_stale'.tr,
                style: TextStyle(
                    color: context.readable(const Color(0xFFE65100)))),
          ),
        if (found == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('sb_start'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.mutedColor)),
          )
        else if (found.items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('sb_empty'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.mutedColor)),
          ),
        for (final item in found?.items ?? const <StockBalance>[]) _row(item),
        if (found?.more == true)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('sb_more'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.mutedColor)),
          ),
      ],
    );
  }

  Widget _row(StockBalance item) {
    final unit = item.unit.isEmpty ? '' : ' ${item.unit}';
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(item.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Text(
                'sb_total'
                    .trParams({'qty': '${stockQuantity(item.total)}$unit'}),
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: context.accentColor),
              ),
            ],
          ),
          if (item.code.isNotEmpty)
            Text(item.code,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          const SizedBox(height: 6),
          for (final place in item.places)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(Icons.warehouse_outlined,
                      size: 16, color: context.mutedColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(place.warehouse.isEmpty
                        ? 'sb_no_warehouse'.tr
                        : place.warehouse),
                  ),
                  Text('${stockQuantity(place.quantity)}$unit'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
