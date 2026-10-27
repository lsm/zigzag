fn main() {
    let data = Box::new(17u8);
    drop(data);
    println!("{}", *data); // expected compile error: moved value
}
