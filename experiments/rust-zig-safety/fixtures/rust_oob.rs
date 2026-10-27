fn main() {
    let data = [1u8, 2, 3];
    let index: usize = std::env::args().nth(1).unwrap_or("8".into()).parse().unwrap();
    println!("{}", data[index]); // expected runtime panic (dynamic index)
}
