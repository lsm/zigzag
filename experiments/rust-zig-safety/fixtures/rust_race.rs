fn main() {
    let mut shared: usize = 0;
    std::thread::scope(|scope| {
        let left = &mut shared;
        scope.spawn(move || *left += 1);
        let right = &mut shared; // expected compile error: overlapping &mut borrows
        scope.spawn(move || *right += 1);
    });
}
