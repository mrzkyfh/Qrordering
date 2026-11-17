import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/pos/presentation/widgets/menu_item_card.dart';
import 'package:qrordering/shared/models/menu_item.dart';

MenuItem _item({required bool isFeatured, String name = 'Ayam Goreng'}) =>
    MenuItem(
      id: 'menu-1',
      outletId: 'outlet-1',
      name: name,
      price: 25000,
      isAvailable: true,
      isActive: true,
      isFeatured: isFeatured,
      sortOrder: 0,
    );

Widget _card(MenuItem item) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 240,
      height: 240,
      child: MenuItemCard(
        item: item,
        quantity: 0,
        onTap: () {},
        onAdd: () {},
        onRemove: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('kartu menu unggulan menampilkan badge', (tester) async {
    await tester.pumpWidget(_card(_item(isFeatured: true)));

    expect(find.text('Unggulan'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
  });

  testWidgets(
    'compact card fits long names and keeps featured and add actions',
    (tester) async {
      var added = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 135,
              height: 140,
              child: MenuItemCard(
                compact: true,
                item: _item(isFeatured: true, name: 'BEEF CHEESE WITH EGG'),
                quantity: 1,
                onTap: () {},
                onAdd: () => added++,
                onRemove: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(find.text('BEEF CHEESE WITH EGG'), findsOneWidget);
      expect(find.text('Rp 25.000'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.add_circle));
      expect(added, 1);
    },
  );

  testWidgets('kartu menu biasa tidak menampilkan badge', (tester) async {
    await tester.pumpWidget(_card(_item(isFeatured: false)));

    expect(find.text('Unggulan'), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
  });
}
