import ScruterAnalytics
import UIKit

/// A UIKit list (screen "Catalog": `CatalogViewController` without its suffix).
final class CatalogViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Catalog"
        tableView.accessibilityIdentifier = "products"
        tableView.register(ProductCell.self, forCellReuseIdentifier: "product")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Product.all.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "product", for: indexPath) as! ProductCell
        cell.configure(Product.all[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        navigationController?.pushViewController(ProductViewController(product: Product.all[indexPath.row]), animated: true)
    }
}

final class ProductCell: UITableViewCell {
    let name = UILabel()
    let add = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        add.setTitle("Add", for: .normal)
        add.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [name, add])
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ p: Product) { name.text = p.name }

    @objc private func addTapped() { Scruter.track("Add to cart", props: ["from": "catalog"]) }
}

/// A UIKit screen with a vertical scroll view (screen "Product").
final class ProductViewController: UIViewController {
    let product: Product
    let scroll = UIScrollView()

    init(product: Product) {
        self.product = product
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = product.name
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let gallery = UIView()
        gallery.accessibilityIdentifier = "gallery"
        gallery.backgroundColor = .systemOrange
        gallery.heightAnchor.constraint(equalToConstant: 360).isActive = true
        let image = UIImageView(image: UIImage(systemName: "cup.and.saucer"))
        image.translatesAutoresizingMaskIntoConstraints = false
        gallery.addSubview(image)
        image.centerXAnchor.constraint(equalTo: gallery.centerXAnchor).isActive = true
        image.centerYAnchor.constraint(equalTo: gallery.centerYAnchor).isActive = true
        let add = UIButton(type: .system)
        add.setTitle("Add to cart", for: .normal)
        add.scruterId = "add_to_cart"
        add.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        let checkout = UIButton(type: .system)
        checkout.setTitle("Checkout", for: .normal)
        checkout.accessibilityIdentifier = "checkout"
        checkout.addTarget(self, action: #selector(checkoutTapped), for: .touchUpInside)
        stack.addArrangedSubview(gallery)
        let title = UILabel()
        title.text = product.name
        title.font = .preferredFont(forTextStyle: .title1)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(add)
        stack.addArrangedSubview(checkout)
        for i in 1...20 {
            let review = UILabel()
            review.numberOfLines = 0
            review.text = "Review \(i): lovely glaze, sturdy, the right size for soup."
            stack.addArrangedSubview(review)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    @objc private func addTapped() {
        Scruter.track("Add to cart", props: ["product": product.name], revenue: product.price, currency: "EUR")
    }

    @objc private func checkoutTapped() {
        navigationController?.pushViewController(CheckoutViewController(), animated: true)
    }
}

/// A UIKit form ("Delivery"): text fields measured field by field, the card and password fields ignored, a masked
/// address preview.
final class CheckoutViewController: UIViewController {
    let form = UIStackView()
    let name = UITextField()
    let postalCode = UITextField()
    let email = UITextField()
    let card = UITextField()
    let password = UITextField()
    let giftWrap = UISwitch()
    let preview = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Checkout"
        form.axis = .vertical
        form.spacing = 12
        form.scruterForm = "Delivery"
        form.translatesAutoresizingMaskIntoConstraints = false
        func field(_ f: UITextField, _ placeholder: String, _ type: UITextContentType?) {
            f.placeholder = placeholder
            f.borderStyle = .roundedRect
            f.textContentType = type
            form.addArrangedSubview(f)
        }
        field(name, "Name", .name)
        field(postalCode, "Postal code", .postalCode)
        field(email, "E-mail", .emailAddress)
        email.keyboardType = .emailAddress
        field(card, "Card number", .creditCardNumber)
        field(password, "Password", .password)
        password.isSecureTextEntry = true
        form.addArrangedSubview(giftWrap)
        preview.text = "12 Potter Street, London"
        preview.scruterMask = true
        form.addArrangedSubview(preview)
        let pay = UIButton(type: .system)
        pay.setTitle("Pay", for: .normal)
        pay.scruterId = "pay"
        pay.addTarget(self, action: #selector(payTapped), for: .touchUpInside)
        form.addArrangedSubview(pay)
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    @objc private func payTapped() {
        let code = postalCode.text ?? ""
        guard code.count == 5, code.allSatisfy(\.isNumber) else {
            Scruter.fieldError("postalCode", kind: .format)
            return
        }
        Scruter.formSent("Delivery")
        Scruter.track("Order", revenue: 49, currency: "EUR")
    }
}
